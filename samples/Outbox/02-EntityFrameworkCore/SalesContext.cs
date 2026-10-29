using DNV.Outbox.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace Outbox.Samples.EntityFrameworkCore;

/// <summary>
/// The application's own context. It owns the business tables AND the outbox table, which is
/// exactly what makes <c>SaveChangesAsync</c> an atomic boundary across both.
/// </summary>
public sealed class SalesContext(DbContextOptions<SalesContext> options) : DbContext(options)
{
	public DbSet<OrderRecord> Orders => this.Set<OrderRecord>();

	protected override void OnModelCreating(ModelBuilder modelBuilder)
	{
		base.OnModelCreating(modelBuilder);

		modelBuilder.Entity<OrderRecord>(entity =>
		{
			entity.ToTable("Orders");
			entity.HasKey(e => e.Id);
			entity.Property(e => e.Id).HasMaxLength(64);
			entity.Property(e => e.TenantId).HasMaxLength(64);
			entity.Property(e => e.CustomerId).HasMaxLength(64);
			entity.Property(e => e.Total).HasPrecision(18, 2);
			entity.Property(e => e.Currency).HasMaxLength(3);
		});

		// Without this the outbox entity is not part of the model, and EnqueueAsync throws
		// OutboxTransactionException rather than silently losing events.
		modelBuilder.ApplyOutboxConfiguration();
	}
}

/// <summary>The persistence shape of an order. The domain's <c>Order</c> stays free of EF concerns.</summary>
public sealed class OrderRecord
{
	public required string Id { get; init; }

	public required string TenantId { get; init; }

	public required string CustomerId { get; init; }

	public required decimal Total { get; init; }

	public required string Currency { get; init; }

	public required DateTimeOffset PlacedAt { get; init; }
}
