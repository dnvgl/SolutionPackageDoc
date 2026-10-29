using DNV.Outbox.Abstractions;

namespace Outbox.Samples.Domain;

/// <summary>
/// An integration event: a fact this bounded context publishes to other services.
/// </summary>
/// <remarks>
/// <see cref="IIntegrationEvent"/> is an empty marker. It exists to keep integration events
/// distinct from domain events, which never leave the bounded context.
/// </remarks>
public sealed record OrderPlaced(
	string OrderId,
	string TenantId,
	string CustomerId,
	decimal Total,
	string Currency,
	DateTimeOffset PlacedAt) : IIntegrationEvent;
