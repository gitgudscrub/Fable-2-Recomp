using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Fable2Launcher;

/// <summary>
/// Project Sparrow's own update signature, on top of GitHub and Velopack's hash checks.
/// Every release package (full and delta .nupkg) gets a "&lt;file&gt;.sig" next to it, signed
/// on the release PC with a private key that never leaves it. The launcher only installs
/// a package whose bytes hash to a value signed by that key, so someone who takes over the
/// GitHub account still can't push code to players.
///
/// ECDSA P-256 with SHA-256 (built into .NET; no extra packages). The signed message is
/// the package's file name and SHA-256, so a valid signature can't be reused for another
/// file. tools/sparrow-sign creates the key and the .sig files.
/// </summary>
public static class UpdateSignature
{
    /// <summary>Public half of the release key (SubjectPublicKeyInfo, base64).</summary>
    public const string ReleasePublicKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyzmNLZ+1Jxdh77NSAbvl60Q2EKAA550ycNCpOS54Pr/Tu5iGcXNqSfdl7ONmKvbSkriVufZv2BIpBQRvPPca5A==";

    private const string Prefix = "ProjectSparrow-update-v1";

    public static byte[] Message(string fileName, string sha256Hex) =>
        Encoding.UTF8.GetBytes($"{Prefix}\n{fileName}\n{sha256Hex.ToLowerInvariant()}\n");

    public static string Sha256File(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    /// <summary>Signature text for a .sig file: base64 of a DER ECDSA signature.</summary>
    public static string Sign(ECDsa privateKey, string fileName, string sha256Hex) =>
        Convert.ToBase64String(privateKey.SignData(Message(fileName, sha256Hex), HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence));

    /// <summary>True only if the signature is well formed and made by the key for this exact file and hash.</summary>
    public static bool Verify(string publicKeyBase64, string fileName, string sha256Hex, string signatureText)
    {
        try
        {
            using ECDsa key = ECDsa.Create();
            key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKeyBase64), out _);
            byte[] signature = Convert.FromBase64String(signatureText.Trim());
            return key.VerifyData(Message(fileName, sha256Hex), signature, HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (FormatException) { return false; }
        catch (CryptographicException) { return false; }
    }

    /// <summary>Checks a downloaded package file against its .sig text.</summary>
    public static bool VerifyFile(string publicKeyBase64, string packagePath, string fileName, string signatureText) =>
        Verify(publicKeyBase64, fileName, Sha256File(packagePath), signatureText);
}
