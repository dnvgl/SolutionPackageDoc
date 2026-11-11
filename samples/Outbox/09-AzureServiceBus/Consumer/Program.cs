using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Configuration;

var configuration = new ConfigurationBuilder()
	.SetBasePath(AppContext.BaseDirectory)
	.AddJsonFile("appsettings.json", optional: false)
	.AddCommandLine(args)
	.Build();

var fullyQualifiedNamespace = configuration["ServiceBus:Namespace"]
	?? throw new InvalidOperationException("ServiceBus:Namespace is not configured.");

var queueName = configuration["ServiceBus:Queue"] ?? "order-events";

// See the publisher for why the credential chain is pinned: VisualStudioCredential is tried
// before AzureCliCredential and can silently resolve a different account, which surfaces here as
// "'Listen' claim(s) are required" even though the role assignment exists.
var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
	ExcludeVisualStudioCredential = true,
	ExcludeAzurePowerShellCredential = true,
	ExcludeInteractiveBrowserCredential = true,
});

await using var client = new ServiceBusClient(fullyQualifiedNamespace, credential);

// PeekLock, not ReceiveAndDelete. The consumer completes the message only after its own work has
// succeeded, which is the receiving half of at-least-once: a crash mid-handler returns the lock
// and the message is redelivered.
await using var processor = client.CreateProcessor(queueName, new ServiceBusProcessorOptions
{
	ReceiveMode = ServiceBusReceiveMode.PeekLock,
	MaxConcurrentCalls = 1,
	AutoCompleteMessages = false,
});

var received = 0;

processor.ProcessMessageAsync += async eventArgs =>
{
	var message = eventArgs.Message;
	var ordinal = Interlocked.Increment(ref received);

	Console.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] RECEIVED #{ordinal}");

	// MessageId is the outbox id. It is the value the broker deduplicates on, and the value the
	// consumer should use if it keeps its own processed-message table.
	Console.WriteLine($"  MessageId (outbox id) : {message.MessageId}");
	Console.WriteLine($"  CorrelationId (event) : {message.CorrelationId}");
	Console.WriteLine($"  Subject (event type)  : {message.Subject}");
	Console.WriteLine($"  EnqueuedTime          : {message.EnqueuedTime:HH:mm:ss}");
	Console.WriteLine($"  DeliveryCount         : {message.DeliveryCount}");

	foreach (var property in message.ApplicationProperties.OrderBy(p => p.Key, StringComparer.Ordinal))
		Console.WriteLine($"  [{property.Key}] {property.Value}");

	Console.WriteLine($"  Body: {message.Body}");
	Console.WriteLine();

	await eventArgs.CompleteMessageAsync(message, eventArgs.CancellationToken);
};

processor.ProcessErrorAsync += eventArgs =>
{
	Console.Error.WriteLine($"[{DateTimeOffset.Now:HH:mm:ss}] ERROR during {eventArgs.ErrorSource}: {eventArgs.Exception.Message}");
	return Task.CompletedTask;
};

await processor.StartProcessingAsync();

Console.WriteLine($"Consuming '{queueName}' on {fullyQualifiedNamespace}.");
Console.WriteLine("Press Ctrl+C to stop.");
Console.WriteLine();

var shutdown = new TaskCompletionSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
	eventArgs.Cancel = true;
	shutdown.TrySetResult();
};

await shutdown.Task;
await processor.StopProcessingAsync();

Console.WriteLine($"Stopped after {received} message(s).");
