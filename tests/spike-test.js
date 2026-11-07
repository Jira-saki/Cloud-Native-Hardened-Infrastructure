import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 20 },  // Ramp-up to 20 VUs
    { duration: '1m',  target: 60 },  // Spike to 60 VUs to push CPU utilization past 50%
    { duration: '30s', target: 0 },   // Scale down and cooldown
  ],
  thresholds: {
    //  error rate to 0% as system test
    http_req_failed: ['rate==0.00'],
    // ยอมรับ p(95) ที่ 2000ms เพื่อรองรับช่วง Pod startup delay ขณะ HPA สเกล 2 -> 8 replicas
    http_req_duration: ['p(95)<2000'],
  },
};

export default function () {
  // ดึงค่า URL จาก Environment Variable หรือ fallback เป็น ALB Hostname
  const baseUrl = __ENV.TARGET_URL || 'http://localhost:8000';
  const url = `${baseUrl}/cpu-burn?duration=0.03`;

  const res = http.get(url);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  sleep(0.05);
}
