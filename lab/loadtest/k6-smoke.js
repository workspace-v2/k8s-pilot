import http from 'k6/http';
import { check } from 'k6';

export const options = {
  maxRedirects: 0,
  scenarios: {
    pilot: {
      executor: 'constant-arrival-rate',
      rate: 5,
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 3,
      maxVUs: 8,
      gracefulStop: '5s',
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.10', abortOnFail: true, delayAbortEval: '10s' }],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const response = http.get(
    'http://community-service/v1/brands',
    { timeout: '2s' },
  );
  check(response, { 'HTTP 200': (result) => result.status === 200 });
}
