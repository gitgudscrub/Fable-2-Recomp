"""Literal HLSL port of a Xenos pixel shader, from the SDK's microcode dump.

    python tools/shaders/ucode_port.py <dump dir> <HASH> [--out file.ps.hlsl]
        [--name "what it draws"]

Reads <dump dir>/shader_<HASH>.ucode.frag (written by --dump_shaders) and the
translated DXBC next to it (shader_<HASH>_*.d3d12_rtv.bin.frag, disassembled
with fxc /dumpbin for the interpolators and the descriptor count), and writes
a stage-1 port in the style of the hand-written ones (lit4.ps.hlsl): one HLSL
statement per ucode instruction, the instruction number in a comment.

Conventions (shaders/xe_common.hlsli has the Xenos reading notes):
  - float constants are packed in ascending register order into K[] (the
    translator does the same), named C<n>;
  - texture bindings are numbered in order of first fetch;
  - co-issued vector and scalar ops read their sources before either
    writes; `ps` is the previous scalar result;
  - the register after the last interpolator holds the guest pixel position
    when the shader reads it.
The port is meant to be checked against the game's own shader (sparrow_split)
before anything is changed in it.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

COMP = 'xyzw'


def find_fxc():
    env = os.environ.get('FXC')
    if env and os.path.isfile(env):
        return env
    found = sorted(glob.glob(r'C:\Program Files (x86)\Windows Kits\10\bin\10.*\x64\fxc.exe'))
    if not found:
        sys.exit('fxc.exe not found')
    return found[-1]


# --- operands -----------------------------------------------------------------
class Src:
    def __init__(self, text):
        t = text.strip()
        self.neg = t.startswith('-')
        if self.neg:
            t = t[1:]
        m = re.fullmatch(r'r_abs\[(\d+)\](?:\.([xyzw]+))?', t)
        if m:
            self.kind, self.idx, self.abs = 'r', int(m.group(1)), True
            sw = m.group(2)
        else:
            m = re.fullmatch(r'([rc])(\d+)(?:\.([xyzw]+))?', t)
            if not m:
                raise ValueError(f'operand {text!r}')
            self.kind, self.idx, self.abs = m.group(1), int(m.group(2)), False
            sw = m.group(3)
        self.swz = sw or 'xyzw'

    def name(self):
        return f'r{self.idx}' if self.kind == 'r' else f'C{self.idx}'

    def comp(self, i):
        """Component i of the swizzle (last one repeats) as an HLSL scalar."""
        c = self.swz[min(i, len(self.swz) - 1)]
        return self.wrap(f'{self.name()}.{c}')

    def vec(self, n=4):
        sw = ''.join(self.swz[min(i, len(self.swz) - 1)] for i in range(n))
        return self.wrap(f'{self.name()}.{sw}')

    def wrap(self, e):
        if self.abs:
            e = f'abs({e})'
        if self.neg:
            e = f'-{e}'
        return e


def dest_parts(text):
    """'r8._yzw' -> ('r8', '_yzw'); 'oC0.xyz_' -> ('o', 'xyz_')."""
    m = re.fullmatch(r'(r\d+|oC0)(?:\.([xyzw01_]+))?', text.strip())
    if not m:
        raise ValueError(f'dest {text!r}')
    reg = 'o' if m.group(1) == 'oC0' else m.group(1)
    mask = m.group(2) or 'xyzw'
    return reg, mask


def write_vec(reg, mask, value):
    """Statements writing a float4 expression `value` (by position) to the
    masked components."""
    out = []
    for i, c in enumerate(mask):
        if c == '_':
            continue
        if c in '01':
            out.append(f'{reg}.{COMP[i]} = {c}.0;')
        else:
            out.append(f'{reg}.{COMP[i]} = {value}.{COMP[i]};')
    return out


def write_scalar(reg, mask, value):
    out = []
    for i, c in enumerate(mask):
        if c == '_':
            continue
        out.append(f'{reg}.{COMP[i]} = {"%s.0" % c if c in "01" else value};')
    return out


def compact(stmts, reg):
    """r.x = v.x; r.y = v.y; -> r.xy = v.xy; (only when contiguous and same
    source and destination letters)."""
    pat = re.compile(rf'^{re.escape(reg)}\.([xyzw]) = (v)\.([xyzw]);$')
    dst, src, rest = '', '', []
    for s in stmts:
        m = pat.match(s)
        if m and m.group(1) == m.group(3):
            dst += m.group(1)
            src += m.group(3)
        else:
            rest.append(s)
    if dst:
        return [f'{reg}.{dst} = v.{src};'] + rest
    return rest


# --- ops ----------------------------------------------------------------------
def vector_expr(op, srcs, mask):
    sat = op.endswith('_sat')
    if sat:
        op = op[:-4]
    a = srcs
    v = lambda s: s.vec(4)
    if op == 'add':
        e = f'({v(a[0])} + {v(a[1])})'
    elif op == 'mul':
        e = f'({v(a[0])} * {v(a[1])})'
    elif op == 'mad':
        e = f'({v(a[0])} * {v(a[1])} + {v(a[2])})'
    elif op == 'max':
        e = f'max({v(a[0])}, {v(a[1])})'
    elif op == 'min':
        e = f'min({v(a[0])}, {v(a[1])})'
    elif op in ('seq', 'sgt', 'sge', 'sne'):
        cmp = {'seq': '==', 'sgt': '>', 'sge': '>=', 'sne': '!='}[op]
        e = f'float4({v(a[0])} {cmp} {v(a[1])})'
    elif op in ('cndeq', 'cndge', 'cndgt'):
        cmp = {'cndeq': '==', 'cndge': '>=', 'cndgt': '>'}[op]
        e = f'({v(a[0])} {cmp} 0.0 ? {v(a[1])} : {v(a[2])})'
    elif op == 'frc':
        e = f'frac({v(a[0])})'
    elif op == 'floor':
        e = f'floor({v(a[0])})'
    elif op == 'trunc':
        e = f'trunc({v(a[0])})'
    elif op == 'dp4':
        e = f'dot({a[0].vec(4)}, {a[1].vec(4)}).xxxx'
    elif op == 'dp3':
        e = f'dot({a[0].vec(3)}, {a[1].vec(3)}).xxxx'
    elif op == 'dp2add':
        e = f'(dot({a[0].vec(2)}, {a[1].vec(2)}) + {a[2].comp(0)}).xxxx'
    elif op == 'max4':
        s = a[0]
        e = f'max(max({s.comp(0)}, {s.comp(1)}), max({s.comp(2)}, {s.comp(3)})).xxxx'
    elif op == 'cube':
        # cube rN, rN.zzxy, rN.yxzz: the direction is rN.xyz.
        if a[0].name() != a[1].name() or a[0].swz != 'zzxy' or a[1].swz != 'yxzz':
            raise ValueError('unexpected cube operands')
        e = f'XeCube({a[0].name()}.xyz)'
    else:
        raise ValueError(f'vector op {op}')
    if sat:
        e = f'saturate({e})'
    return e


def scalar_expr(op, srcs):
    sat = op.endswith('_sat')
    if sat:
        op = op[:-4]
    a = srcs
    one = lambda: a[0].comp(0)
    two = lambda: (a[0].comp(0), a[0].comp(1))
    if op == 'retain_prev':
        e = 'ps'
    elif op in ('muls', 'adds', 'subs', 'maxs', 'mins'):
        x, y = two()
        e = {'muls': f'{x} * {y}', 'adds': f'{x} + {y}', 'subs': f'{x} - {y}',
             'maxs': f'max({x}, {y})', 'mins': f'min({x}, {y})'}[op]
    elif op in ('mulsc', 'addsc', 'subsc'):
        x, y = a[0].comp(0), a[1].comp(0)
        e = {'mulsc': f'{x} * {y}', 'addsc': f'{x} + {y}', 'subsc': f'{x} - ({y})'}[op]
    elif op == 'muls_prev':
        e = f'{one()} * ps'
    elif op == 'adds_prev':
        e = f'{one()} + ps'
    elif op in ('rsq', 'rsqc', 'rsqf'):
        e = f'rsqrt({one()})'
    elif op in ('rcp', 'rcpc', 'rcpf'):
        e = f'rcp({one()})'
    elif op == 'sqrt':
        e = f'sqrt({one()})'
    elif op in ('log', 'logc'):
        e = f'log2({one()})'
    elif op == 'exp':
        e = f'exp2({one()})'
    elif op == 'frcs':
        e = f'frac({one()})'
    elif op == 'floors':
        e = f'floor({one()})'
    elif op == 'truncs':
        e = f'trunc({one()})'
    elif op in ('sgts', 'sges', 'seqs', 'snes'):
        cmp = {'sgts': '>', 'sges': '>=', 'seqs': '==', 'snes': '!='}[op]
        e = f'({one()} {cmp} 0.0 ? 1.0 : 0.0)'
    elif op == 'sin':
        e = f'sin({one()})'
    elif op == 'cos':
        e = f'cos({one()})'
    elif op in ('setp_gt', 'setp_ge', 'setp_eq', 'setp_ne'):
        cmp = {'setp_gt': '>', 'setp_ge': '>=', 'setp_eq': '==', 'setp_ne': '!='}[op]
        return f'{one()}', cmp  # handled by the caller
    else:
        raise ValueError(f'scalar op {op}')
    if sat:
        e = f'saturate({e})'
    return e, None


def split_operands(s):
    return [x.strip() for x in s.split(',')] if s.strip() else []


# --- parse --------------------------------------------------------------------
def parse(path):
    """Returns a list of items: ('exec', cond) | ('alu', n, pred, vop, vargs,
    sop, sargs) | ('fetch', n, pred, kind, dest, coord, tf, opts) | ('jmp',
    pred, label) | ('label', name) | ('end',)."""
    lines = open(path, encoding='utf-8').read().splitlines()
    items = []
    i = 0
    cur = None
    while i < len(lines):
        line = lines[i]
        head = re.match(r'\s*/\*\s*([\d.]+)\s*\*/\s*(.*)$', line)
        body = head.group(2).strip() if head else line.strip()
        num = head.group(1) if head else None
        if body.startswith('label '):
            items.append(('label', body.split()[1]))
            i += 1
            continue
        if num and '.' in num:  # control flow
            m = re.match(r'(?:\((!?)p0\)\s*)?(\w+)\s*(.*)$', body)
            neg, op, rest = m.group(1), m.group(2), m.group(3)
            pred = None if m.group(1) is None else (neg != '!')
            rest = rest.split('//')[0].strip()
            if op in ('exec', 'exece'):
                items.append(('exec', ('p', pred) if pred is not None else None))
                if op == 'exece':
                    items.append(('end_marker',))
            elif op == 'cexec':
                bm = re.match(r'(!?)b(\d+)', rest)
                items.append(('exec', ('b', int(bm.group(2)), bm.group(1) != '!')))
            elif op == 'jmp':
                items.append(('jmp', pred, rest))
            elif op in ('alloc', 'cnop', 'nop'):
                pass
            else:
                raise ValueError(f'control flow {body}')
            i += 1
            continue
        if not num:
            i += 1
            continue
        n = int(num)
        if body == 'serialize':
            i += 1
            body = lines[i].strip()
        pm = re.match(r'\((!?)p0\)\s*(.*)$', body)
        pred = None
        if pm:
            pred = pm.group(1) != '!'
            body = pm.group(2)
        op, _, args = body.partition(' ')
        if op.startswith('tfetch'):
            parts = split_operands(args)
            items.append(('fetch', n, pred, op, parts[0], parts[1], parts[2], parts[3:]))
            i += 1
            continue
        # ALU: vector line then a "+ scalar" line.
        vargs = split_operands(args)
        sop, sargs, spred = None, [], None
        if i + 1 < len(lines) and lines[i + 1].strip().startswith('+'):
            sl = lines[i + 1].strip()[1:].strip()
            pm = re.match(r'\((!?)p0\)\s*(.*)$', sl)
            if pm:
                spred = pm.group(1) != '!'
                sl = pm.group(2)
            sop, _, sa = sl.partition(' ')
            sargs = split_operands(sa)
            i += 1
        items.append(('alu', n, pred, op, vargs, sop, sargs))
        i += 1
    return items


# --- emit ---------------------------------------------------------------------
def emit(items, interp_count):
    consts, tfs, out = set(), [], []
    fetch_kinds = {}
    reads_pos = False
    max_reg = interp_count
    written = set(range(interp_count))
    pos_reg = interp_count

    def note_src(s):
        nonlocal reads_pos, max_reg
        if s.kind == 'c':
            consts.add(s.idx)
        else:
            max_reg = max(max_reg, s.idx)
            if s.idx == pos_reg and s.idx not in written:
                reads_pos = True

    def note_dest(reg):
        nonlocal max_reg
        if reg.startswith('r'):
            k = int(reg[1:])
            written.add(k)
            max_reg = max(max_reg, k)

    indent = 1
    block_open = False
    body = []

    def put(s, n=None):
        pad = '  ' * (indent + (1 if block_open else 0))
        body.append(f'{pad}{s}' + (f'  // {n}' if n is not None else ''))

    for it in items:
        kind = it[0]
        if kind == 'exec':
            if block_open:
                body.append('  ' * indent + '}')
                block_open = False
            cond = it[1]
            if cond:
                if cond[0] == 'b':
                    c = f'XeBool({cond[1]})' if cond[2] else f'!XeBool({cond[1]})'
                else:
                    c = 'p0' if cond[1] else '!p0'
                body.append('  ' * indent + f'if ({c}) {{')
                block_open = True
            continue
        if kind == 'end_marker':
            continue
        if kind == 'jmp':
            # (!p0) jmp L: the predicated instructions that follow carry their
            # own (p0); nothing to emit.
            continue
        if kind == 'label':
            continue
        if kind == 'fetch':
            _, n, pred, op, dest, coord, tf, opts = it
            tfn = int(tf[2:])
            reg, mask = dest_parts(dest)
            note_dest(reg)
            cs = Src(coord)
            note_src(cs)
            offx = offy = 0
            for o in opts:
                k, _, val = o.partition('=')
                if k == 'OffsetX':
                    offx = int(float(val))
                elif k == 'OffsetY':
                    offy = int(float(val))
                elif k in ('FetchValidOnly', 'MagFilter', 'MinFilter', 'MipFilter',
                           'UseComputedLOD', 'UseRegisterGradients', 'AnisoFilter'):
                    pass
                else:
                    raise ValueError(f'fetch option {o}')
            if tfn not in tfs:
                tfs.append(tfn)
            if op == 'tfetch2D':
                if offx or offy:
                    fetch_kinds.setdefault(tfn, set()).add('off')
                    call = f'TF{tfn}_OFF({cs.vec(2)}, {offx}, {offy})'
                else:
                    fetch_kinds.setdefault(tfn, set()).add('2d')
                    call = f'TF{tfn}({cs.vec(2)})'
            elif op == 'tfetch1D':
                fetch_kinds.setdefault(tfn, set()).add('1d')
                call = f'TF{tfn}({cs.comp(0)})'
            elif op == 'tfetchCube':
                fetch_kinds.setdefault(tfn, set()).add('cube')
                call = f'TF{tfn}({cs.vec(3)})'
            else:
                raise ValueError(op)
            stm = []
            for i2, c in enumerate(mask):
                if c == '_':
                    continue
                stm.append(f'{reg}.{COMP[i2]} = {c + ".0" if c in "01" else "t." + c};')
            line = f'{{ float4 t = {call}; ' + ' '.join(stm) + ' }'
            if pred is not None:
                line = f'if ({"p0" if pred else "!p0"}) {line}'
            put(line, n)
            continue
        # ALU
        _, n, pred, vop, vargs, sop, sargs = it
        stm = []
        vexpr = sexpr = None
        vdest = sdest = None
        setp = None
        if vargs:
            vdest = dest_parts(vargs[0])
            vsrcs = [Src(x) for x in vargs[1:]]
            for s in vsrcs:
                note_src(s)
            if vdest[1].strip('_'):
                vexpr = vector_expr(vop, vsrcs, vdest[1])
        if sop:
            sdest = dest_parts(sargs[0])
            ssrcs = [Src(x) for x in sargs[1:]]
            for s in ssrcs:
                note_src(s)
            sexpr, setp = scalar_expr(sop, ssrcs)
        decl, writes = [], []
        if vexpr is not None:
            decl.append(f'float4 v = {vexpr};')
            note_dest(vdest[0])
            writes += compact(write_vec(vdest[0], vdest[1], 'v'), vdest[0])
        if sexpr is not None and not (sexpr == 'ps' and setp is None):
            if setp is not None:
                decl.append(f'bool pn = {sexpr} {setp} 0.0;')
                decl.append('float s = pn ? 0.0 : 1.0;')
            else:
                decl.append(f'float s = {sexpr};')
            if sdest[1].strip('_'):
                note_dest(sdest[0])
                writes += write_scalar(sdest[0], sdest[1], 's')
            if setp is not None:
                writes.append('p0 = pn;')
            writes.append('ps = s;')
        elif sexpr == 'ps' and sdest and sdest[1].strip('_'):
            note_dest(sdest[0])
            writes += write_scalar(sdest[0], sdest[1], 'ps')
        if not writes:
            continue
        line = '{ ' + ' '.join(decl + writes) + ' }'
        if pred is not None:
            line = f'if ({"p0" if pred else "!p0"}) {line}'
        put(line, n)
    if block_open:
        body.append('  ' * indent + '}')
    return body, sorted(consts), tfs, fetch_kinds, reads_pos, max_reg


def dumpbin_info(dump, hash_):
    bins = sorted(glob.glob(os.path.join(dump, f'shader_{hash_}_*.d3d12_rtv.bin.frag')))
    if not bins:
        sys.exit('no translated shader in the dump')
    out = os.path.join(os.environ.get('TEMP', '.'), f'ucode_port_{hash_}.asm')
    subprocess.run([find_fxc(), '/nologo', '/dumpbin', bins[0], '/Fc', out], check=True,
                   capture_output=True)
    text = open(out, encoding='utf-8', errors='replace').read()
    floats = int(re.search(r'float4 xe_float_constants\[(\d+)\]', text).group(1))
    desc = int(re.search(r'uint4 xe_descriptor_indices\[(\d+)\]', text).group(1))
    interps = []
    for m in re.finditer(r'dcl_input_ps (linear(?: centroid)?(?: noperspective)?) v(\d+)\.xyzw', text):
        interps.append((int(m.group(2)), 'centroid' in m.group(1)))
    coverage = 'dcl_output oMask' in text
    return floats, desc, interps, coverage


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('hash')
    ap.add_argument('--out')
    ap.add_argument('--name', default='')
    args = ap.parse_args()
    h = args.hash.upper()
    items = parse(os.path.join(args.dump, f'shader_{h}.ucode.frag'))
    floats, desc, interps, coverage = dumpbin_info(args.dump, h)
    body, consts, tfs, kinds, reads_pos, max_reg = emit(items, len(interps))
    if len(consts) != floats:
        sys.exit(f'constant count {len(consts)} != translator {floats}')
    need_desc = (1 + 3 * len(tfs) + 3) // 4
    # The translator's reflection can round the count down by one (25 indices
    # declared as 6 uint4s); the shader still reads index 24, so declare
    # enough for every binding.
    if desc not in (need_desc, need_desc - 1):
        sys.exit(f'descriptor count {need_desc} != translator {desc} (bindings {tfs})')
    desc = need_desc
    L = []
    L.append(f'// Fable II pixel shader {h}{": " + args.name if args.name else ""}.')
    L.append('// Built only for Project Sparrow (tools/shaders/build_replace.py --sparrow).')
    L.append('//')
    L.append('// Stage 1: a literal port of the game\'s Xenos microcode, generated by')
    L.append('// tools/shaders/ucode_port.py (comments give the ucode instruction numbers;')
    L.append('// reading notes in xe_common.hlsli).')
    L.append('')
    L.append(f'#define XE_FLOAT_CONSTANTS {floats}')
    L.append(f'#define XE_DESCRIPTOR_INDICES {desc}')
    L.append('#include "xe_common.hlsli"')
    L.append('#if SPARROW')
    L.append('#include "sparrow_common.hlsli"')
    L.append('#endif')
    L.append('')
    for k, c in enumerate(consts):
        L.append(f'#define C{c} K[{k}]')
    L.append('')
    L.append('// Texture bindings of this shader, in the translator\'s order.')
    for b, tf in enumerate(tfs):
        ks = kinds[tf]
        if '2d' in ks:
            L.append(f'#define TF{tf}(uv) Fetch({tf}, {b}, uv, false)')
        if 'off' in ks:
            L.append(f'#define TF{tf}_OFF(uv, ox, oy) FetchOffset({tf}, {b}, uv, int2(ox, oy))')
        if '1d' in ks:
            L.append(f'#define TF{tf}(x) Fetch({tf}, {b}, float2(x, 0.0), true)')
        if 'cube' in ks:
            L.append(f'#define TF{tf}(stf) FetchCube({tf}, {b}, stf)')
    L.append('')
    L.append('struct PSInputPort {')
    for idx, cen in interps:
        L.append(f'  {"centroid " if cen else ""}float4 v{idx} : TEXCOORD{idx};')
    L.append('  float4 position : SV_Position;')
    L.append('  bool front_face : SV_IsFrontFace;')
    L.append('};')
    L.append('')
    sig = 'float4 main(PSInputPort input, out uint coverage : SV_Coverage) : SV_Target0 {' if coverage \
        else 'float4 main(PSInputPort input) : SV_Target0 {'
    L.append(sig)
    regs = [f'r{k} = input.v{k}' for k, _ in interps]
    L.append('  float4 ' + ', '.join(regs) + ';')
    rest = [f'r{k} = 0.0' for k in range(len(interps), max_reg + 1)]
    for k in range(0, len(rest), 8):
        L.append('  float4 ' + ', '.join(rest[k:k + 8]) + ';')
    L.append('  float4 o = 0.0;')
    L.append('  float ps = 0.0;')
    L.append('  bool p0 = false;')
    if reads_pos:
        L.append(f'  r{len(interps)}.xy = GuestPixelPosition(input.position, input.front_face);')
    L.append('')
    L += body
    L.append('')
    L.append('  AlphaTest(o.w);')
    if coverage:
        L.append('  coverage = AlphaToMask(o.w, input.position.xy);')
    L.append('  return o * xe_color_exp_bias.x;')
    L.append('}')
    text = '\n'.join(L) + '\n'
    if args.out:
        open(args.out, 'w', encoding='utf-8', newline='\n').write(text)
        print(f'{args.out}: {len(body)} lines, {len(consts)} constants, bindings {tfs}')
    else:
        print(text)


if __name__ == '__main__':
    main()
