const express = require('express');
const os = require('os');
const Redis = require('ioredis');

const app = express();
const PORT = process.env.PORT || 3000;
const APP_ENV = process.env.NODE_ENV || 'production';
const APP_NAME = process.env.APP_NAME || 'ServerAdmin Core Service';
const REDIS_HOST = process.env.REDIS_HOST || 'cache';
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || '';

let redisClient = null;
let redisStatus = 'Disabled / Not Connected';

if (process.env.ENABLE_REDIS === 'true') {
  try {
    redisClient = new Redis({
      host: REDIS_HOST,
      port: Number(REDIS_PORT),
      password: REDIS_PASSWORD || undefined,
      retryStrategy(times) {
        if (times > 3) return null;
        return Math.min(times * 100, 2000);
      }
    });

    redisClient.on('connect', () => {
      redisStatus = 'Connected to Redis backend';
      console.log(`[Cache] Successfully connected to Redis at ${REDIS_HOST}:${REDIS_PORT}`);
    });

    redisClient.on('error', (err) => {
      redisStatus = `Redis Error: ${err.message}`;
    });
  } catch (err) {
    redisStatus = `Init failed: ${err.message}`;
  }
}

app.use(express.json());

// Request logger
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.originalUrl} ${res.statusCode} ${duration}ms - Client IP: ${req.headers['x-forwarded-for'] || req.socket.remoteAddress}`);
  });
  next();
});

// Root welcome / status landing page
app.get('/', async (req, res) => {
  let visitCount = 1;
  if (redisClient && redisStatus.includes('Connected')) {
    try {
      visitCount = await redisClient.incr('site:pageviews');
    } catch {
      // fallback
    }
  }

  res.send(`
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>${APP_NAME}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 40px; }
        .card { background: #1e293b; border-radius: 12px; padding: 32px; max-width: 800px; margin: 0 auto; box-shadow: 0 10px 25px -5px rgba(0,0,0,0.5); border: 1px solid #334155; }
        h1 { color: #38bdf8; margin-top: 0; }
        .badge { display: inline-block; padding: 4px 10px; border-radius: 9999px; font-size: 13px; font-weight: 600; background: #0284c7; color: #ffffff; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-top: 24px; }
        .metric-box { background: #0f172a; padding: 16px; border-radius: 8px; border: 1px solid #334155; }
        .metric-title { font-size: 12px; color: #94a3b8; text-transform: uppercase; }
        .metric-value { font-size: 20px; font-weight: bold; color: #f1f5f9; margin-top: 8px; }
        pre { background: #020617; padding: 16px; border-radius: 6px; overflow-x: auto; color: #a5f3fc; border: 1px solid #1e293b; }
        .footer { margin-top: 32px; text-align: center; font-size: 13px; color: #64748b; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>${APP_NAME} <span class="badge">${APP_ENV}</span></h1>
        <p>This containerized service is deployed via <strong>Docker Compose</strong> and served through an <strong>Nginx Reverse Proxy</strong> with least-privilege security configurations.</p>
        
        <div class="grid">
          <div class="metric-box">
            <div class="metric-title">Host Hostname</div>
            <div class="metric-value">${os.hostname()}</div>
          </div>
          <div class="metric-box">
            <div class="metric-title">Platform</div>
            <div class="metric-value">${os.type()} ${os.arch()}</div>
          </div>
          <div class="metric-box">
            <div class="metric-title">Uptime</div>
            <div class="metric-value">${Math.floor(os.uptime() / 60)} minutes</div>
          </div>
          <div class="metric-box">
            <div class="metric-title">Redis Cache</div>
            <div class="metric-value" style="font-size:15px; color:#34d399;">${redisStatus}</div>
          </div>
        </div>

        <h3 style="margin-top:28px; color:#cbd5e1;">Proxy & Client Telemetry</h3>
        <pre>Client IP: ${req.headers['x-forwarded-for'] || req.socket.remoteAddress}
X-Real-IP: ${req.headers['x-real-ip'] || 'Direct Connection'}
X-Forwarded-Proto: ${req.headers['x-forwarded-proto'] || 'HTTP'}
Host Header: ${req.headers['host']}</pre>

        <div class="footer">
          Linux Server Administration & Deployment Automation Lab • Ubuntu • Docker • Nginx
        </div>
      </div>
    </body>
    </html>
  `);
});

// JSON Status API
app.get('/api/status', (req, res) => {
  res.json({
    app: APP_NAME,
    environment: APP_ENV,
    status: 'ONLINE',
    timestamp: new Date().toISOString(),
    system: {
      hostname: os.hostname(),
      platform: os.platform(),
      release: os.release(),
      uptime_seconds: os.uptime(),
      load_avg: os.loadavg(),
      total_mem_mb: Math.round(os.totalmem() / 1024 / 1024),
      free_mem_mb: Math.round(os.freemem() / 1024 / 1024),
    },
    cache: {
      status: redisStatus
    },
    proxy: {
      client_ip: req.headers['x-forwarded-for'] || req.socket.remoteAddress,
      real_ip: req.headers['x-real-ip'] || null,
      proto: req.headers['x-forwarded-proto'] || 'http',
      host: req.headers['host']
    }
  });
});

// Health check endpoint for Docker & Nginx
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// Environment variable exposure check (safe parameters only)
app.get('/api/env', (req, res) => {
  res.json({
    NODE_ENV: process.env.NODE_ENV,
    PORT: process.env.PORT,
    APP_NAME: process.env.APP_NAME,
    ENABLE_REDIS: process.env.ENABLE_REDIS,
    REDIS_HOST: process.env.REDIS_HOST
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${APP_NAME}] Application started on http://0.0.0.0:${PORT} in ${APP_ENV} mode.`);
});

