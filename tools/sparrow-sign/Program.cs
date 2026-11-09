// sparrow-sign: release signing for Project Sparrow updates.
//
//   sparrow-sign keygen [--key <file>]          create the key (refuses to overwrite)
//   sparrow-sign pubkey [--key <file>]          print the public key for UpdateSignature.cs
//   sparrow-sign sign   [--key <file>] <files>  write <file>.sig next to each package
//   sparrow-sign verify <files>                 check <file>.sig against the launcher's key
//
// Default key: %USERPROFILE%\.project-sparrow\update-signing-key.pem. Keep it off GitHub
// and back it up: losing it means installed launchers can't take updates any more.
using System.Security.Cryptography;
using Fable2Launcher;

string keyPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
    ".project-sparrow", "update-signing-key.pem");
var rest = new List<string>();
for (int i = 1; i < args.Length; i++)
{
    if (args[i] == "--key" && i + 1 < args.Length) keyPath = args[++i];
    else rest.Add(args[i]);
}

switch (args.FirstOrDefault())
{
    case "keygen":
        if (File.Exists(keyPath)) return Fail($"{keyPath} already exists; not overwriting it.");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(keyPath))!);
        using (ECDsa key = ECDsa.Create(ECCurve.NamedCurves.nistP256))
        {
            File.WriteAllText(keyPath, key.ExportPkcs8PrivateKeyPem());
            Console.WriteLine($"Private key: {keyPath}  (back this up; never commit it)");
            Console.WriteLine("Public key:  " + Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()));
        }
        return 0;

    case "pubkey":
        using (ECDsa key = LoadKey(keyPath))
            Console.WriteLine(Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()));
        return 0;

    case "sign":
        if (rest.Count == 0) return Fail("No files to sign.");
        using (ECDsa key = LoadKey(keyPath))
        {
            string publicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
            if (publicKey != UpdateSignature.ReleasePublicKey)
                return Fail("This key doesn't match UpdateSignature.ReleasePublicKey; launchers would reject these packages.");
            foreach (string file in rest)
            {
                string name = Path.GetFileName(file);
                string signature = UpdateSignature.Sign(key, name, UpdateSignature.Sha256File(file));
                File.WriteAllText(file + ".sig", signature + "\n");
                Console.WriteLine($"signed {name}");
            }
        }
        return 0;

    case "verify":
        int bad = 0;
        foreach (string file in rest)
        {
            string sigPath = file + ".sig";
            bool ok = File.Exists(sigPath) && UpdateSignature.VerifyFile(UpdateSignature.ReleasePublicKey, file,
                Path.GetFileName(file), File.ReadAllText(sigPath));
            Console.WriteLine($"{(ok ? "ok  " : "BAD ")} {Path.GetFileName(file)}");
            if (!ok) bad++;
        }
        return bad == 0 ? 0 : 1;

    default:
        Console.Error.WriteLine("usage: sparrow-sign keygen|pubkey|sign|verify [--key <file>] [files]");
        return 2;
}

static ECDsa LoadKey(string path)
{
    if (!File.Exists(path)) throw new FileNotFoundException($"Signing key not found: {path}. Run 'sparrow-sign keygen' first.");
    ECDsa key = ECDsa.Create();
    key.ImportFromPem(File.ReadAllText(path));
    return key;
}

static int Fail(string message)
{
    Console.Error.WriteLine(message);
    return 1;
}
