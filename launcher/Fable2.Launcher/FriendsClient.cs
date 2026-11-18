using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Fable2Launcher;

/// <summary>
/// Talks to the co-op friends service (tools/mp_friends/friends.py): accounts,
/// friends, presence and invites. The service address comes from coop.json next
/// to the launcher (added when a release is packaged) or the
/// PROJECT_SPARROW_FRIENDS environment variable; without one, accounts are off.
/// The sign-in token is kept encrypted for this Windows user (DPAPI).
/// </summary>
public sealed class FriendsClient
{
    public sealed record Friend(string Name, string Status, bool InSession);
    public sealed record FriendList(string Username, List<Friend> Friends, List<string> Incoming, List<string> Outgoing);
    public sealed record PendingInvite(long Id, string From, string Code, int Age);

    public sealed class FriendsException(string message) : Exception(message);

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _http;
    private readonly string _tokenPath;
    private string? _token;

    public string? ServiceUrl { get; }
    public bool Available => ServiceUrl is not null;
    public bool SignedIn => _token is not null;
    public string? Username { get; private set; }
    /// <summary>Relay address from the service (host:port), once fetched.</summary>
    public string? Relay { get; private set; }

    public FriendsClient(string home, string installFolder)
    {
        ServiceUrl = FindServiceUrl(installFolder);
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        if (ServiceUrl is not null) _http.BaseAddress = new Uri(ServiceUrl.TrimEnd('/') + "/");
        _tokenPath = Path.Combine(home, "account.dat");
        LoadToken();
    }

    private static string? FindServiceUrl(string installFolder)
    {
        string? url = Environment.GetEnvironmentVariable("PROJECT_SPARROW_FRIENDS");
        if (string.IsNullOrWhiteSpace(url))
        {
            try
            {
                string path = Path.Combine(installFolder, "coop.json");
                if (!File.Exists(path)) path = Path.Combine(AppContext.BaseDirectory, "coop.json");
                if (File.Exists(path))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(path));
                    if (doc.RootElement.TryGetProperty("friends", out var f)) url = f.GetString();
                }
            }
            catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        }
        if (string.IsNullOrWhiteSpace(url)) return null;
        // Plain http only for a service on this PC (tests).
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != Uri.UriSchemeHttps && !(uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback)) return null;
        return uri.ToString();
    }

    // ------------------------------------------------------------ token storage

    private void LoadToken()
    {
        try
        {
            if (!File.Exists(_tokenPath)) return;
            byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(_tokenPath), null, DataProtectionScope.CurrentUser);
            string[] parts = Encoding.UTF8.GetString(plain).Split('\n');
            if (parts.Length == 2) { _token = parts[0]; Username = parts[1]; }
        }
        catch (Exception exception) when (exception is IOException or CryptographicException or UnauthorizedAccessException) { }
    }

    private void SaveToken(string? token, string? username)
    {
        _token = token;
        Username = username;
        try
        {
            if (token is null) { File.Delete(_tokenPath); return; }
            byte[] secret = ProtectedData.Protect(Encoding.UTF8.GetBytes(token + "\n" + username), null,
                DataProtectionScope.CurrentUser);
            File.WriteAllBytes(_tokenPath, secret);
        }
        catch (Exception exception) when (exception is IOException or CryptographicException or UnauthorizedAccessException) { }
    }

    // ------------------------------------------------------------ calls

    private async Task<JsonElement> Call(HttpMethod method, string path, object? body = null)
    {
        if (!Available) throw new FriendsException("Friends aren't available in this build.");
        using var request = new HttpRequestMessage(method, path);
        if (_token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        // A sized body (JsonContent streams without a Content-Length, which the service needs).
        if (body is not null)
            request.Content = new StringContent(JsonSerializer.Serialize(body, Json), Encoding.UTF8, "application/json");
        HttpResponseMessage response;
        try { response = await _http.SendAsync(request); }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            throw new FriendsException("Can't reach the friends server. Check your internet connection.");
        }
        using (response)
        {
            JsonElement json;
            try { json = (await response.Content.ReadFromJsonAsync<JsonElement>(Json)).Clone(); }
            catch (Exception) { json = default; }
            if (response.IsSuccessStatusCode) return json;
            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized && _token is not null && path != "v1/password"
                && path != "v1/delete-account")
                SaveToken(null, null);  // expired or signed out elsewhere
            string message = json.ValueKind == JsonValueKind.Object && json.TryGetProperty("error", out var e)
                ? e.GetString() ?? "" : "";
            throw new FriendsException(message.Length > 0 ? message : $"The friends server said {(int)response.StatusCode}.");
        }
    }

    public async Task LoadConfig()
    {
        JsonElement json = await Call(HttpMethod.Get, "v1/config");
        string? relay = json.TryGetProperty("relay", out var r) ? r.GetString() : null;
        Relay = string.IsNullOrWhiteSpace(relay) ? null : relay;
    }

    public async Task SignIn(string username, string password, bool create)
    {
        JsonElement json = await Call(HttpMethod.Post, create ? "v1/register" : "v1/login",
            new { username, password });
        SaveToken(json.GetProperty("token").GetString(), json.GetProperty("username").GetString());
    }

    public async Task SignOut()
    {
        try { if (SignedIn) await Call(HttpMethod.Post, "v1/logout", new { }); }
        catch (FriendsException) { }
        SaveToken(null, null);
    }

    public async Task<FriendList> Friends()
    {
        JsonElement json = await Call(HttpMethod.Get, "v1/friends");
        return json.Deserialize<FriendList>(Json) ?? throw new FriendsException("Bad reply from the friends server.");
    }

    public async Task<string> Request(string username) =>
        (await Call(HttpMethod.Post, "v1/friends/request", new { username })).GetProperty("result").GetString() ?? "";

    public Task Accept(string username) => Call(HttpMethod.Post, "v1/friends/accept", new { username });
    public Task Remove(string username) => Call(HttpMethod.Post, "v1/friends/remove", new { username });
    public Task SendInvite(string username) => Call(HttpMethod.Post, "v1/invite", new { username });
    public Task Dismiss(long id) => Call(HttpMethod.Post, "v1/invites/dismiss", new { id });

    public Task Presence(string status, string? sessionCode) =>
        Call(HttpMethod.Post, "v1/presence", new { status, session_code = sessionCode ?? "" });

    public async Task<List<PendingInvite>> Invites()
    {
        JsonElement json = await Call(HttpMethod.Get, "v1/invites");
        return json.GetProperty("invites").Deserialize<List<PendingInvite>>(Json) ?? [];
    }

    /// <summary>Best-effort "offline" on exit (short timeout, never throws).</summary>
    public void GoOfflineQuietly()
    {
        if (!Available || !SignedIn) return;
        try { Task.Run(() => Presence("offline", null)).Wait(TimeSpan.FromSeconds(2)); } catch (Exception) { }
    }
}
