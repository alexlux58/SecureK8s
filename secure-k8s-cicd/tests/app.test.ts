import request from 'supertest';
import { app } from '../src/index';

describe('Application Health', () => {
  test('GET /health should return healthy status', async () => {
    const response = await request(app)
      .get('/health')
      .expect(200);
    
    expect(response.body.status).toBe('healthy');
    expect(response.body.timestamp).toBeDefined();
  });

  test('GET /ready should return ready status', async () => {
    const response = await request(app)
      .get('/ready')
      .expect(200);
    
    expect(response.body.status).toBe('ready');
    expect(response.body.timestamp).toBeDefined();
  });

  test('GET /metrics should return prometheus metrics', async () => {
    const response = await request(app)
      .get('/metrics')
      .expect(200);
    
    expect(response.text).toContain('http_requests_total');
    expect(response.text).toContain('http_request_duration_seconds');
  });

  test('GET /api/message should return message', async () => {
    const response = await request(app)
      .get('/api/message')
      .expect(200);
    
    expect(response.body.id).toBeDefined();
    expect(response.body.message).toBe('Hello from secure K8s app!');
    expect(response.body.timestamp).toBeDefined();
  });
});

describe('Security Headers', () => {
  test('Should include security headers', async () => {
    const response = await request(app)
      .get('/health')
      .expect(200);
    
    expect(response.headers['x-content-type-options']).toBe('nosniff');
    expect(response.headers['x-frame-options']).toBe('DENY');
    expect(response.headers['x-xss-protection']).toBe('0');
  });
});
