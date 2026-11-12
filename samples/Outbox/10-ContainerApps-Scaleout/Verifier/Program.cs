using System.Text.Json;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Configuration;

var configuration = new ConfigurationBuilder()
	.AddJsonFile("appsettings.json", optional: false)
	.AddCommandLine(args)
	.Build();

var fullyQualifiedNamespace = configuration["ServiceBus:FullyQualifiedNamespace"]!;
var topicName = configuration["ServiceBus:Topic"]!;
var subscriptionName = configuration["ServiceBus:Subscription"]!;

// Seconds of silence before the verifier decides nothing more is coming.
var idleSeconds = int.Parse(configuration["idle"] ?? "20");

// Drain mode empties the subscription and reports nothing else. Run it immediately before a
// burst: anything left over from a previous run would otherwise be counted as part of this one.
var drain = string.Equals(configuration["drain"], "true", StringComparison.OrdinalIgnoreCase);

// How many messages this run must see before it is allowed to pass. Defaults to 0, which still
// refuses to pass on an empty run - see the check at the bottom.
var expected = int.Parse(configuration["expect"] ?? "0");

// ---------------------------------------------------------------------------------------------
// The credential chain is pinned, and that is not defensive clutter.
//
// DefaultAzureCredential tries VisualStudioCredential BEFORE AzureCliCredential. On a machine
// where Visual Studio is signed in as a different account from `az login` - which is normal in
// an enterprise tenant - every receive fails with "'Listen' claim(s) are required", while the
// portal shows the role assignment as perfectly correct. It looks exactly like RBAC propagation
// lag and it is not. Excluding the other sources makes the identity the same one you logged in
// with and granted the role to.
// ---------------------------------------------------------------------------------------------
var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
	ExcludeVisualStudioCredential = true,
	ExcludeAzurePowerShellCredential = true,
	ExcludeInteractiveBrowserCredential = true,
});

await using var client = new ServiceBusClient(fullyQualifiedNamespace, credential);
await using var receiver = client.CreateReceiver(topicName, subscriptionName, new ServiceBusReceiverOptions
{
	ReceiveMode = ServiceBusReceiveMode.ReceiveAndDelete,
});

Console.WriteLine($"namespace    : {fullyQualifiedNamespace}");
Console.WriteLine($"topic        : {topicName}");
Console.WriteLine($"subscription : {subscriptionName}");
Console.WriteLine($"mode         : {(drain ? "drain" : "verify")}, stopping after {idleSeconds}s of silence{(expected > 0 ? $", expecting {expected} message(s)" : string.Empty)}");
Console.WriteLine();

var total = 0;
var firstLogged = false;
var counts = new Dictionary<string, int>(StringComparer.Ordinal);

while (true)
{
	var batch = await receiver.ReceiveMessagesAsync(
		maxMessages: 100,
		maxWaitTime: TimeSpan.FromSeconds(idleSeconds));

	if (batch.Count == 0)
		break;

	foreach (var message in batch)
	{
		total++;

		// Identity is the CloudEvents id, which the outbox sets to the outbox id - NOT the
		// Service Bus MessageId.
		//
		// Dapr mints a fresh MessageId for every publish call, so counting those would make a
		// genuine double dispatch look like two perfectly ordinary distinct messages and this
		// verifier would pass no matter what. The CloudEvents id is the value the outbox
		// guarantees is stable across retries, and therefore the only one worth counting.
		var identity =
			(message.ApplicationProperties.TryGetValue("cloudevent.id", out var property) ? property?.ToString() : null)
			?? ReadCloudEventId(message.Body)
			?? $"(no cloudevent id #{total})";

		counts[identity] = counts.GetValueOrDefault(identity) + 1;

		if (!firstLogged && !drain)
		{
			firstLogged = true;
			Console.WriteLine("First message:");
			Console.WriteLine($"  MessageId     : {message.MessageId}  (Dapr's own, changes on every publish)");
			Console.WriteLine($"  CloudEvents id: {identity}  (the outbox id - this is what gets counted)");
			Console.WriteLine($"  Properties    : {string.Join(", ", message.ApplicationProperties.Select(p => $"{p.Key}={p.Value}"))}");
			Console.WriteLine($"  Body          : {message.Body}");
			Console.WriteLine();
		}
	}

	Console.WriteLine($"  received {total} so far...");
}

Console.WriteLine();

if (drain)
{
	Console.WriteLine($"Drained {total} leftover message(s). The subscription is now empty.");
	return 0;
}

var duplicates = counts.Where(pair => pair.Value > 1).ToList();

Console.WriteLine("RESULT");
Console.WriteLine($"  messages received : {total}");
Console.WriteLine($"  distinct ids      : {counts.Count}");
Console.WriteLine($"  duplicated ids    : {duplicates.Count}");

foreach (var duplicate in duplicates.Take(10))
	Console.WriteLine($"    {duplicate.Key} delivered {duplicate.Value} times");

Console.WriteLine();

// A run that received nothing must not pass.
//
// Without this, the most likely failure in the whole sample - the dispatcher never ran, the
// Dapr component is misconfigured, the subscription was drained by a stray terminal - produces
// "0 received, 0 duplicates, PASS". Pass --expect with the number of orders enqueued and the
// verifier has to actually see them.
if (expected > 0 && total < expected)
{
	Console.WriteLine($"FAIL - expected at least {expected} message(s) but received {total}.");
	return 1;
}

if (expected == 0 && total == 0)
{
	Console.WriteLine("FAIL - no messages at all. Pass --expect <n> to make this check explicit.");
	return 1;
}

if (duplicates.Count == 0)
{
	Console.WriteLine("PASS - every outbox record reached the topic exactly once.");
	return 0;
}

// A non-zero exit, because this is a test. Duplicate detection is off on this topic precisely so
// that a double dispatch has somewhere to show up.
Console.WriteLine("FAIL - the same outbox record was delivered more than once.");
return 1;

static string? ReadCloudEventId(BinaryData body)
{
	try
	{
		using var document = JsonDocument.Parse(body);
		return document.RootElement.TryGetProperty("id", out var id) ? id.GetString() : null;
	}
	catch (JsonException)
	{
		return null;
	}
}
