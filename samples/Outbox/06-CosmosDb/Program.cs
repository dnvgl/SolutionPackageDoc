using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.Cosmos;
using DNV.Outbox.Hosting;
using DNV.Outbox.Http;
using Microsoft.Azure.Cosmos;
using Outbox.Samples.CosmosDb;
using Outbox.Samples.Domain;

var builder = WebApplication.CreateBuilder(args);

var cosmos = builder.Configuration.GetSection("Cosmos");
var endpoint = cosmos["Endpoint"] ?? throw new InvalidOperationException("Cosmos:Endpoint is not configured.");
var key = cosmos["Key"] ?? throw new InvalidOperationException("Cosmos:Key is not configured.");
var databaseId = cosmos["DatabaseId"] ?? "sales";
var containerId = cosmos["ContainerId"] ?? "orders";
var partitionKeyPath = cosmos["PartitionKeyPath"] ?? "/tenantId";

// 1. The application owns the CosmosClient. The outbox deliberately does not create one: an outbox
//    write is only transactional when it rides on the same batch as the business documents, which
//    means it has to use the same client, container and partition the application already uses.
builder.Services.AddSingleton(_ =>
{
	var options = new CosmosClientOptions
	{
		// Both the business documents below and the library's outbox documents are written through
		// this serializer, so the two must agree. The library's document declares explicit property
		// names, which win over this policy, so the shapes stay compatible either way.
		SerializerOptions = new CosmosSerializationOptions
		{
			PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase,
		},
	};

	if (cosmos.GetValue<bool>("TrustSelfSignedCertificate"))
	{
		// The emulator serves a self-signed certificate that is usually, but not always, installed
		// into the local trust store. Accepting it unconditionally keeps the sample runnable.
		//
		// This is emulator-only. Against a real account it would disable the protection that stops
		// a proxy impersonating Cosmos, so it is gated behind configuration rather than hard-coded.
		options.ConnectionMode = ConnectionMode.Gateway;
		options.HttpClientFactory = () => new HttpClient(new HttpClientHandler
		{
			ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,
		});
	}

	return new CosmosClient(endpoint, key, options);
});

// 2. The outbox stores its documents in the SAME container as the orders.
//
//    This looks wrong the first time you see it - an outbox table normally gets its own home. In
//    Cosmos it is the only option that works: a transactional batch spans one container and one
//    logical partition, so an outbox in its own container could not commit with the business write
//    and the pattern would lose the guarantee that is its entire point.
builder.Services.AddOutbox()
	.UseCosmos(options =>
	{
		options.DatabaseId = databaseId;
		options.ContainerId = containerId;

		// Single level only. The library writes this property onto its own documents so they land
		// in the same logical partition as the order they were written with.
		options.PartitionKeyPath = partitionKeyPath;

		// Development convenience: creates the database and container at startup, before the
		// dispatcher's first poll. Production provisioning belongs in a deployment pipeline.
		options.AutoProvision = true;
		options.ProvisionedThroughput = 400;
	})
	.AddHttpDestination("receiver", http =>
	{
		http.Endpoint = new Uri(builder.Configuration["Outbox:ReceiverEndpoint"]!);
	})
	.AddDispatcher(dispatcher =>
	{
		// Aggressive for a demo. Production defaults are far less chatty - and in Cosmos every poll
		// costs request units.
		dispatcher.PollInterval = TimeSpan.FromSeconds(1);
		dispatcher.BatchSize = 20;
	});

var app = builder.Build();

Container OrdersContainer(CosmosClient client) => client.GetContainer(databaseId, containerId);

// 3. One batch, two kinds of document, one commit.
app.MapPost("/orders", async (
	PlaceOrderRequest request,
	ICosmosOutboxBatchFactory batchFactory,
	CancellationToken cancellationToken) =>
{
	var order = Order.Place(request.TenantId, request.CustomerId, request.Total);

	// The partition key value - not the container - is the transaction boundary.
	var batch = batchFactory.ForPartition(order.TenantId);

	batch.CreateItem(OrderDocument.From(order));

	var messages = await batch.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest([Destinations.Receiver], eventType: nameof(OrderPlaced), eventVersion: 1)
		{
			// Required by the Cosmos provider. It must match the batch's partition, otherwise the
			// enqueue is rejected at the call site rather than silently committing somewhere else.
			PartitionKey = order.TenantId,
		},
		cancellationToken);

	// Until this line nothing has been sent to Cosmos at all. The order and the outbox record are
	// written by one request and either both exist or neither does.
	await batch.ExecuteAsync(cancellationToken);

	return Results.Ok(new
	{
		OrderId = order.Id,
		order.TenantId,
		EventId = messages[0].EventId,
		OutboxId = messages[0].OutboxId,
		messages[0].Destination,
	});
});

// 4. The same thing, with one operation guaranteed to fail, to show what "atomic" buys you.
//
//    The batch stages a perfectly good order, a perfectly good outbox record, and a replace of a
//    document that does not exist. Cosmos rejects the whole batch, so the order is never written -
//    and neither is the outbox record, which means no phantom event is ever published for an order
//    that does not exist.
app.MapPost("/orders/doomed", async (
	PlaceOrderRequest request,
	ICosmosOutboxBatchFactory batchFactory,
	CancellationToken cancellationToken) =>
{
	var order = Order.Place(request.TenantId, request.CustomerId, request.Total);
	var missingId = $"does-not-exist-{Guid.CreateVersion7()}";

	var batch = batchFactory.ForPartition(order.TenantId);

	batch.CreateItem(OrderDocument.From(order));

	await batch.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest([Destinations.Receiver], eventType: nameof(OrderPlaced), eventVersion: 1)
		{
			PartitionKey = order.TenantId,
		},
		cancellationToken);

	// Replacing an absent document returns 404, which fails the batch. Every other operation then
	// reports 424 (failed dependency) - that is Cosmos saying "rolled back", not "also broken".
	batch.ReplaceItem(missingId, OrderDocument.From(order) with { Id = missingId });

	try
	{
		await batch.ExecuteAsync(cancellationToken);
	}
	catch (OutboxTransactionException ex)
	{
		return Results.Conflict(new
		{
			OrderId = order.Id,
			order.TenantId,
			Rejected = true,
			Message = ex.Message,
			Explanation = "The batch was rejected, so neither the order nor its outbox record exists. Check with GET /orders/{tenantId}/{id} and GET /container/{tenantId}.",
		});
	}

	// Reached only if the deliberately doomed operation somehow succeeded, which would mean this
	// endpoint has stopped demonstrating anything.
	return Results.Problem("The batch that was supposed to fail committed. The sample is no longer demonstrating atomicity.");
});

app.MapGet("/orders/{tenantId}/{id}", async (
	string tenantId,
	string id,
	CosmosClient client,
	CancellationToken cancellationToken) =>
{
	try
	{
		var response = await OrdersContainer(client).ReadItemAsync<OrderDocument>(
			id, new PartitionKey(tenantId), cancellationToken: cancellationToken);

		return Results.Ok(response.Resource);
	}
	catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
	{
		return Results.NotFound(new { TenantId = tenantId, Id = id });
	}
});

// 5. Proves the colocation claim: one container holding both kinds of document, told apart only by
//    the 'recordType' discriminator the library stamps on its own documents.
app.MapGet("/container/{tenantId}", async (
	string tenantId,
	CosmosClient client,
	CancellationToken cancellationToken) =>
{
	var container = OrdersContainer(client);

	return Results.Ok(new
	{
		Database = databaseId,
		Container = containerId,
		PartitionKey = tenantId,
		Orders = await CountAsync(container, tenantId, "c.type = 'order'", cancellationToken),
		OutboxRecords = await CountAsync(
			container, tenantId, $"c.recordType = '{OutboxMessage.DeliveryRecordType}'", cancellationToken),
		Note = "Both counts come from the same container. That is what makes the write transactional.",
	});
});

// 6. The outbox documents themselves, so the record lifecycle is visible without a Data Explorer.
app.MapGet("/outbox/{tenantId}", async (
	string tenantId,
	CosmosClient client,
	CancellationToken cancellationToken) =>
{
	var query = new QueryDefinition(
		"""
		SELECT c.id, c.eventId, c.destination, c.eventType, c.status, c.attemptCount,
		       c.createdAt, c.deliveredAt, c.lastError, c.traceParent
		FROM c
		WHERE c.recordType = @recordType
		ORDER BY c.createdAt
		""")
		.WithParameter("@recordType", OutboxMessage.DeliveryRecordType);

	var results = new List<OutboxRecordView>();
	using var iterator = OrdersContainer(client).GetItemQueryIterator<OutboxRecordView>(
		query, requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(tenantId) });

	while (iterator.HasMoreResults)
	{
		results.AddRange(await iterator.ReadNextAsync(cancellationToken));
	}

	return Results.Ok(results.Select(r => new
	{
		r.Id,
		r.EventId,
		r.Destination,
		r.EventType,
		Status = ((OutboxStatus)r.Status).ToString(),
		r.AttemptCount,
		r.CreatedAt,
		r.DeliveredAt,
		r.LastError,
		r.TraceParent,
	}));
});

// A readiness probe, not just a liveness one: it reads the container, so it only answers once
// AutoProvision has finished creating it. Without that, a caller could race the provisioner.
app.MapGet("/health", async (CosmosClient client, CancellationToken cancellationToken) =>
{
	try
	{
		await OrdersContainer(client).ReadContainerAsync(cancellationToken: cancellationToken);
		return Results.Ok("healthy");
	}
	catch (CosmosException ex)
	{
		return Results.Problem($"Cosmos is not ready: {ex.StatusCode}.", statusCode: 503);
	}
	catch (HttpRequestException ex)
	{
		return Results.Problem($"Cannot reach Cosmos at {endpoint}: {ex.Message}", statusCode: 503);
	}
});

// A browsable index, so hitting the bare port in a browser explains the sample rather than 404ing.
app.MapGet("/", () => Results.Ok(new
{
	Sample = "06-CosmosDb",
	Description = "Commits an order document and its outbox record in ONE Cosmos transactional batch, inside one container and one logical partition - the only scope in which Cosmos is atomic.",
	Cosmos = new { Endpoint = endpoint, Database = databaseId, Container = containerId, PartitionKeyPath = partitionKeyPath },
	Endpoints = new[]
	{
		"GET  /                        this index",
		"GET  /health                  readiness probe (reads the container)",
		"POST /orders                  place an order (body: { tenantId, customerId, total })",
		"POST /orders/doomed           place an order in a batch that cannot commit; expect HTTP 409 and no writes",
		"GET  /orders/{tenantId}/{id}  read one order document",
		"GET  /container/{tenantId}    counts of business and outbox documents in the SAME container",
		"GET  /outbox/{tenantId}       the outbox documents and their status",
	},
	Hint = "POST /orders a few times, then compare GET /container/acme with http://localhost:5100/deliveries.",
}));

app.Run();

static async Task<int> CountAsync(
	Container container,
	string tenantId,
	string predicate,
	CancellationToken cancellationToken)
{
	using var iterator = container.GetItemQueryIterator<int>(
		new QueryDefinition($"SELECT VALUE COUNT(1) FROM c WHERE {predicate}"),
		requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(tenantId) });

	var total = 0;
	while (iterator.HasMoreResults)
	{
		foreach (var count in await iterator.ReadNextAsync(cancellationToken))
		{
			total += count;
		}
	}

	return total;
}
