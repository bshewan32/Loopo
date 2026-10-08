# iLoop routing proxy

This service keeps the GraphHopper API key server-side. The iOS app calls `/route`; it never receives or embeds the provider key.

## Local run

```bash
cd routing-proxy
export GRAPH_HOPPER_API_KEY="your-new-key"
npm start
```

Health check:

```bash
curl http://localhost:10000/health
```

Test route request:

```bash
curl -X POST http://localhost:10000/route \
  -H 'content-type: application/json' \
  -d '{"latitude":-37.8136,"longitude":144.9631,"targetDistanceKm":30,"seed":1234}'
```

## Render deployment

1. In the Render dashboard, create a **New Web Service** from `bshewan32/Loopo`.
2. Use the repository's `render.yaml`, or set:
   - Root Directory: `routing-proxy`
   - Build Command: `npm install`
   - Start Command: `npm start`
3. Add the secret environment variable:

   ```text
   GRAPH_HOPPER_API_KEY=<new GraphHopper key>
   ```

4. Deploy and verify:

   ```text
   https://<your-render-service>.onrender.com/health
   ```

5. Put that URL in `RouteGenerationService.swift` as `proxyBaseURL`.

## Security notes

- Do not commit `.env` files or GraphHopper keys.
- The old key was exposed in the iOS source and Git history. Revoke it in the GraphHopper dashboard immediately; removing it from source does not invalidate it.
- The proxy validates coordinates, distance (2–300 km), and seed values, and limits each client address to 30 requests per 10 minutes.
- For a larger public launch, replace the in-memory limiter with a shared store and add per-user authentication or signed request tokens.
