const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const root = __dirname;
const publicRoot = path.join(root, 'public');
const dataPath = fs.existsSync(path.join(root, 'data', 'yardbids.json'))
  ? path.join(root, 'data', 'yardbids.json')
  : path.join(root, 'yardbids.json');
const port = Number(process.env.PORT || 3030);
const host = process.env.RENDER ? '0.0.0.0' : '127.0.0.1';
const stripeConfigPath = path.join(root, 'stripe-test.env');

function loadPrivateConfig() {
  if (!fs.existsSync(stripeConfigPath)) return;
  for (const line of fs.readFileSync(stripeConfigPath, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (match && !process.env[match[1]]) process.env[match[1]] = match[2].trim();
  }
}

loadPrivateConfig();

function stripeSecretKey() {
  return String(process.env.STRIPE_SECRET_KEY || '')
    .trim()
    .replace(/^(['\"])(.*)\1$/, '$2');
}

function supabasePublicConfig() {
  const supabaseUrl = String(process.env.SUPABASE_URL || '').trim().replace(/^(['\"])(.*)\1$/, '$2');
  const supabasePublishableKey = String(process.env.SUPABASE_PUBLISHABLE_KEY || '').trim().replace(/^(['\"])(.*)\1$/, '$2');
  return { supabaseUrl, supabasePublishableKey };
}

function readData() {
  const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
  data.users ||= [];
  data.auctions ||= [];
  data.listings ||= [];
  data.messages ||= [];
  data.orders ||= [];
  return data;
}

function writeData(data) {
  fs.writeFileSync(dataPath, JSON.stringify(data, null, 2));
}

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; });
    request.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}); }
      catch { reject(new Error('Invalid JSON')); }
    });
  });
}

function makeId(prefix) {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function createStripeCheckoutSession(order, siteUrl) {
  const fields = new URLSearchParams({
    mode: 'payment',
    success_url: `${siteUrl}/?stripe_checkout=success&order_id=${encodeURIComponent(order.id)}`,
    cancel_url: `${siteUrl}/?stripe_checkout=cancelled&order_id=${encodeURIComponent(order.id)}`,
    'line_items[0][price_data][currency]': 'usd',
    'line_items[0][price_data][product_data][name]': order.title,
    'line_items[0][price_data][unit_amount]': String(order.amountCents),
    'line_items[0][quantity]': '1',
    'metadata[yardbids_order_id]': order.id
  }).toString();

  return new Promise((resolve, reject) => {
    const request = https.request({
      hostname: 'api.stripe.com',
      path: '/v1/checkout/sessions',
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${stripeSecretKey()}:`).toString('base64')}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(fields)
      }
    }, (stripeResponse) => {
      let body = '';
      stripeResponse.on('data', (chunk) => { body += chunk; });
      stripeResponse.on('end', () => {
        try {
          const parsed = JSON.parse(body);
          if (stripeResponse.statusCode >= 400) return reject(new Error(parsed.error?.message || 'Stripe checkout could not be created'));
          resolve(parsed);
        } catch (error) {
          reject(new Error('Stripe returned an unexpected response'));
        }
      });
    });
    request.on('error', reject);
    request.write(fields);
    request.end();
  });
}

function serveFile(response, requestedPath) {
  const safePath = path.normalize(requestedPath).replace(/^([.][.][/\\])+/, '');
  const relativePath = safePath === '/' ? 'index.html' : safePath;
  const publicFilePath = path.join(publicRoot, relativePath);
  const rootFilePath = path.join(root, relativePath);
  const filePath = fs.existsSync(publicFilePath) ? publicFilePath : rootFilePath;
  if ((!filePath.startsWith(publicRoot) && !filePath.startsWith(root)) || !fs.existsSync(filePath)) {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Not found');
    return;
  }
  const ext = path.extname(filePath);
  const contentType = ext === '.html' ? 'text/html; charset=utf-8' : 'application/octet-stream';
  response.writeHead(200, { 'Content-Type': contentType });
  fs.createReadStream(filePath).pipe(response);
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const parts = url.pathname.split('/').filter(Boolean);

  if (request.method === 'GET' && url.pathname === '/api/health') {
    return sendJson(response, 200, { ok: true, service: 'yardbids-local-mvp' });
  }

  if (request.method === 'GET' && url.pathname === '/api/public-config') {
    const config = supabasePublicConfig();
    if (!config.supabaseUrl || !config.supabasePublishableKey) {
      return sendJson(response, 503, { error: 'Supabase is not configured yet' });
    }
    return sendJson(response, 200, config);
  }

  if (request.method === 'GET' && url.pathname === '/api/auctions') {
    return sendJson(response, 200, readData().auctions);
  }

  if (request.method === 'GET' && parts[0] === 'api' && parts[1] === 'auctions' && parts.length === 3) {
    const auction = readData().auctions.find((item) => item.id === parts[2]);
    return auction
      ? sendJson(response, 200, auction)
      : sendJson(response, 404, { error: 'Auction not found' });
  }

  if (request.method === 'GET' && url.pathname === '/api/users') {
    return sendJson(response, 200, readData().users);
  }

  if (request.method === 'POST' && url.pathname === '/api/users') {
    try {
      const input = await readJson(request);
      const displayName = String(input.displayName || '').trim();
      if (displayName.length < 2 || displayName.length > 30) {
        return sendJson(response, 400, { error: 'Display name must be 2–30 characters' });
      }
      const data = readData();
      const user = { id: makeId('user'), displayName, createdAt: new Date().toISOString() };
      data.users.push(user);
      writeData(data);
      return sendJson(response, 201, user);
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  if (request.method === 'GET' && url.pathname === '/api/messages') {
    const userId = url.searchParams.get('userId');
    const messages = readData().messages.filter((message) => !userId || message.fromUserId === userId || message.toUserId === userId);
    return sendJson(response, 200, messages);
  }

  if (request.method === 'POST' && url.pathname === '/api/messages') {
    try {
      const input = await readJson(request);
      const fromUserId = String(input.fromUserId || '').trim();
      const toUserId = String(input.toUserId || '').trim();
      const text = String(input.text || '').trim();
      if (!fromUserId || !toUserId || !text || text.length > 1000) {
        return sendJson(response, 400, { error: 'Sender, recipient, and a message up to 1,000 characters are required' });
      }
      const data = readData();
      if (!data.users.some((user) => user.id === fromUserId) || !data.users.some((user) => user.id === toUserId)) {
        return sendJson(response, 404, { error: 'Sender or recipient not found' });
      }
      const message = { id: makeId('message'), fromUserId, toUserId, text, createdAt: new Date().toISOString() };
      data.messages.push(message);
      writeData(data);
      return sendJson(response, 201, message);
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  if (request.method === 'GET' && url.pathname === '/api/orders') {
    const userId = url.searchParams.get('userId');
    const orders = readData().orders.filter((order) => !userId || order.buyerId === userId || order.sellerId === userId);
    return sendJson(response, 200, orders);
  }

  if (request.method === 'GET' && parts[0] === 'api' && parts[1] === 'orders' && parts.length === 3) {
    const order = readData().orders.find((item) => item.id === parts[2]);
    return order
      ? sendJson(response, 200, order)
      : sendJson(response, 404, { error: 'Order not found' });
  }

  if (request.method === 'POST' && url.pathname === '/api/orders') {
    try {
      const input = await readJson(request);
      const buyerId = String(input.buyerId || '').trim();
      const auctionId = String(input.auctionId || '').trim();
      const deliveryMethod = input.deliveryMethod === 'shipping' ? 'shipping' : 'pickup';
      const data = readData();
      const auction = data.auctions.find((item) => item.id === auctionId);
      if (!buyerId || !auction) return sendJson(response, 400, { error: 'A buyer and auction are required' });
      if (!data.users.some((user) => user.id === buyerId)) return sendJson(response, 404, { error: 'Buyer not found' });
      const order = {
        id: makeId('order'),
        auctionId: auction.id,
        buyerId,
        sellerDisplayName: auction.seller,
        title: auction.title,
        amountCents: auction.currentBidCents,
        deliveryMethod,
        status: 'pending_secure_payment',
        createdAt: new Date().toISOString()
      };
      data.orders.unshift(order);
      writeData(data);
      return sendJson(response, 201, order);
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  if (request.method === 'POST' && url.pathname === '/api/stripe/checkout-session') {
    try {
      if (!stripeSecretKey().startsWith('sk_test_')) {
        return sendJson(response, 503, { error: 'Stripe test mode is not configured yet' });
      }
      const input = await readJson(request);
      const data = readData();
      const order = data.orders.find((item) => item.id === input.orderId);
      if (!order) return sendJson(response, 404, { error: 'Order not found' });
      const forwardedProtocol = String(request.headers['x-forwarded-proto'] || '').split(',')[0].trim();
      const protocol = forwardedProtocol || (request.socket.encrypted ? 'https' : 'http');
      const siteUrl = `${protocol}://${request.headers.host}`;
      const session = await createStripeCheckoutSession(order, siteUrl);
      order.status = 'stripe_checkout_created';
      order.stripeCheckoutSessionId = session.id;
      writeData(data);
      return sendJson(response, 201, { url: session.url, orderId: order.id });
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  if (request.method === 'POST' && parts[0] === 'api' && parts[1] === 'auctions' && parts[3] === 'bids') {
    try {
      const input = await readJson(request);
      const amountCents = Number(input.amountCents);
      const data = readData();
      const auction = data.auctions.find((item) => item.id === parts[2]);
      if (!auction) return sendJson(response, 404, { error: 'Auction not found' });
      if (!Number.isInteger(amountCents) || amountCents <= auction.currentBidCents) {
        return sendJson(response, 400, { error: 'Bid must be higher than the current bid' });
      }
      auction.currentBidCents = amountCents;
      auction.bidderCount += 1;
      auction.bids.unshift({ amountCents, bidder: input.bidder || 'Taylor', createdAt: new Date().toISOString() });
      writeData(data);
      return sendJson(response, 201, auction);
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  if (request.method === 'POST' && url.pathname === '/api/listings') {
    try {
      const input = await readJson(request);
      if (!input.title || !input.startingBidCents) {
        return sendJson(response, 400, { error: 'A title and starting bid are required' });
      }
      const data = readData();
      const listing = { id: `listing-${Date.now()}`, ...input, createdAt: new Date().toISOString() };
      data.listings.unshift(listing);
      writeData(data);
      return sendJson(response, 201, listing);
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  }

  return serveFile(response, url.pathname);
});

server.listen(port, host, () => {
  console.log(`YardBids development server running on ${host}:${port}`);
});
