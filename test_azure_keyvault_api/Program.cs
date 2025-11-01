using Azure.Extensions.AspNetCore.Configuration.Secrets;
using Azure.Identity;

var builder = WebApplication.CreateBuilder(args);

// Configure Key Vault BEFORE building the app
if (!builder.Environment.IsDevelopment())
{
    var keyVaultName = builder.Configuration["AzureKeyVaultName"];
    var keyVaultUri = new Uri($"https://{keyVaultName}.vault.azure.net/");

    builder.Configuration.AddAzureKeyVault(keyVaultUri, new DefaultAzureCredential(),
        new AzureKeyVaultConfigurationOptions
        {
            ReloadInterval = TimeSpan.FromMinutes(1)
        });
}

var app = builder.Build();

app.MapGet("/", (IConfiguration config) => Results.Ok(new
{
    SecretValue = config["ApiKey"] ?? "None"
}));

app.MapGet("/users", () =>
{
    var users = new[]
    {
        new { Id = 1, Name = "Alice" },
        new { Id = 2, Name = "Bob" }
    };
    return Results.Ok(users);
});

app.Run();