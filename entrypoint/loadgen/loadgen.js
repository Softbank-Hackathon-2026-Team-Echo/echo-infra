// 시연용 합성 트래픽 (k6). 진입점 공인 주소로 초당 RATE 건을 고르게 보낸다.
// 60초마다 끝나고 요약을 찍는다. 컨테이너가 무한 루프로 다시 돌린다 (deployment.yaml).
import http from "k6/http";

const RATE = Number(__ENV.RATE || 50);
const TARGET_URL = __ENV.TARGET_URL; // 예: http://34.158.202.103
const TARGET_HOST = __ENV.TARGET_HOST; // 예: shop.echoport.uk (진입점은 Host 로 앱을 고른다)
const TARGET_PATH = __ENV.TARGET_PATH || "/";

export const options = {
  discardResponseBodies: true,
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: __ENV.DURATION || "60s",
      preAllocatedVUs: Math.max(5, Math.ceil(RATE / 5)),
      maxVUs: Math.max(20, RATE * 2),
    },
  },
  summaryTrendStats: ["avg", "p(95)", "max"],
};

export default function () {
  http.get(`${TARGET_URL}${TARGET_PATH}`, {
    headers: { Host: TARGET_HOST, "User-Agent": "echo-loadgen/1" },
    tags: { name: "entry" },
  });
}
