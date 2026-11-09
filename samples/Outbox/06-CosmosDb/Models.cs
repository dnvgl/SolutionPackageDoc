using Outbox.Samples.Domain;

namespace Outbox.Samples.CosmosDb;

internal static class Destinations
{
	public const string Receiver = "receiver";
}

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);

/// <summary>
/// The order as it is stored. <c>Type</c> is this application's own discriminator; the library
/// stamps <c>recordType</c> on its documents, so the two kinds of document never collide even
/// though they share a container.
/// </summary>
internal sealed record OrderDocument(
	string Id,
	string TenantId,
	string CustomerId,
	decimal Total,
	string Currency,
	DateTimeOffset PlacedAt)
{
	public string Type => "order";

	public static OrderDocument From(Order order) =>
		new(order.Id, order.TenantId, order.CustomerId, order.Total, order.Currency, order.PlacedAt);
}

/// <summary>A projection of the library's outbox document, for the read endpoints.</summary>
internal sealed record OutboxRecordView(
	string Id,
	Guid EventId,
	string Destination,
	string EventType,
	int Status,
	int AttemptCount,
	string? CreatedAt,
	string? DeliveredAt,
	string? LastError,
	string? TraceParent);
