using System.Text;
using DNV.Outbox.Abstractions;

namespace Outbox.Samples.MultipleDestinations;

/// <summary>
/// A deliberately simple custom transport: write the delivery to a file.
/// </summary>
/// <remarks>
/// <para>
/// This is the whole contract for a transport. Implement <see cref="IOutboxDestination"/>, return
/// an <see cref="OutboxOutcome"/>, and the dispatcher takes care of claiming, retrying, backoff
/// and dead-lettering.
/// </para>
/// <para>
/// The three outcomes are not interchangeable. <see cref="OutboxOutcome.Success"/> marks the row
/// delivered. <see cref="OutboxOutcome.Transient"/> schedules a retry with exponential backoff.
/// <see cref="OutboxOutcome.Permanent"/> goes straight to the dead-letter state, because resending
/// an identical request would fail identically — burning the retry budget would only delay the
/// moment an operator notices.
/// </para>
/// <para>
/// Expected transport failures are returned, not thrown. Cancellation is the exception: it means
/// the host is shutting down or the claim was lost, and it must propagate rather than be reported
/// as any kind of delivery result.
/// </para>
/// </remarks>
public sealed class FileDestination(string name, string directory) : IOutboxDestination
{
	/// <inheritdoc />
	public string Name => name;

	/// <inheritdoc />
	public async Task<OutboxOutcome> SendAsync(
		OutboxMessage message,
		CancellationToken cancellationToken = default)
	{
		ArgumentNullException.ThrowIfNull(message);

		try
		{
			Directory.CreateDirectory(directory);

			// Naming the file after the OutboxId makes the write idempotent: a retry of this
			// delivery rewrites the same file rather than appending a duplicate.
			var path = Path.Combine(directory, $"{message.OutboxId}.json");

			// Payload is ReadOnlyMemory<byte>, because the library never assumes a text encoding.
			var content = new StringBuilder()
				.AppendLine($"// outboxId={message.OutboxId} eventId={message.EventId}")
				.AppendLine($"// eventType={message.EventType} v{message.EventVersion} traceparent={message.TraceParent}")
				.AppendLine(Encoding.UTF8.GetString(message.Payload.Span))
				.ToString();

			await File.WriteAllTextAsync(path, content, cancellationToken);

			return OutboxOutcome.Success;
		}
		catch (IOException ex)
		{
			// The disk might be busy or the file locked. Worth another attempt.
			return OutboxOutcome.Transient(ex.Message, ex);
		}
		catch (UnauthorizedAccessException ex)
		{
			// Permissions will not fix themselves. Do not burn retries on this.
			return OutboxOutcome.Permanent(ex.Message, ex);
		}
	}
}
