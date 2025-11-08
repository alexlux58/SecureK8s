import express from 'express';
import helmet from 'helmet';
import * as amqp from 'amqplib';
import { register, Counter, Histogram } from 'prom-client';

const app = express();
const port = process.env.PORT || 3000;

// Security middleware
app.use(helmet());
app.use(express.json({ limit: '1mb' }));

// Metrics
const requestCounter = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status']
});

const requestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  buckets: [0.1, 0.5, 1, 2, 5]
});

// Health endpoints
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

app.get('/ready', (req, res) => {
  res.json({ status: 'ready', timestamp: new Date().toISOString() });
});

app.get('/metrics', (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(register.metrics());
});

// Sample API endpoint
app.get('/api/message', async (req, res) => {
  const end = requestDuration.startTimer();
  
  try {
    // Simulate RabbitMQ interaction
    const message = { 
      id: Math.random().toString(36),
      message: 'Hello from secure K8s app!',
      timestamp: new Date().toISOString()
    };
    
    requestCounter.inc({ method: 'GET', path: '/api/message', status: '200' });
    res.json(message);
  } catch (error) {
    requestCounter.inc({ method: 'GET', path: '/api/message', status: '500' });
    res.status(500).json({ error: 'Internal server error' });
  } finally {
    end();
  }
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
