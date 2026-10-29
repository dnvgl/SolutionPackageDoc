namespace Outbox.Samples.Domain;

/// <summary>
/// A deliberately small order aggregate. The samples are about the outbox, not about this.
/// </summary>
public sealed class Order
{
	private Order(string id, string tenantId, string customerId, decimal total, string currency)
	{
		this.Id = id;
		this.TenantId = tenantId;
		this.CustomerId = customerId;
		this.Total = total;
		this.Currency = currency;
		this.PlacedAt = DateTimeOffset.UtcNow;
	}

	public string Id { get; }

	/// <summary>The partition key used by the Cosmos sample. Harmless elsewhere.</summary>
	public string TenantId { get; }

	public string CustomerId { get; }

	public decimal Total { get; }

	public string Currency { get; }

	public DateTimeOffset PlacedAt { get; }

	public static Order Place(string tenantId, string customerId, decimal total, string currency = "USD")
	{
		ArgumentException.ThrowIfNullOrWhiteSpace(tenantId);
		ArgumentException.ThrowIfNullOrWhiteSpace(customerId);

		if (total <= 0)
		{
			throw new ArgumentOutOfRangeException(nameof(total), total, "An order total must be positive.");
		}

		return new Order(Guid.CreateVersion7().ToString(), tenantId, customerId, total, currency);
	}

	/// <summary>Builds the integration event announcing this order to other bounded contexts.</summary>
	public OrderPlaced ToIntegrationEvent() =>
		new(this.Id, this.TenantId, this.CustomerId, this.Total, this.Currency, this.PlacedAt);
}
