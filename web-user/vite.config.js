import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig(function (_a) {
    var mode = _a.mode;
    var env = loadEnv(mode, ".", "");
    var proxyTarget = env.VITE_PROXY_TARGET || "http://localhost:8081";
    return {
        plugins: [react()],
        server: {
            port: 5173,
            proxy: {
                "/v1": {
                    target: proxyTarget,
                    changeOrigin: true,
                },
                "/ws": {
                    target: proxyTarget,
                    changeOrigin: true,
                    ws: true,
                },
                "/healthz": {
                    target: proxyTarget,
                    changeOrigin: true,
                },
                "/readyz": {
                    target: proxyTarget,
                    changeOrigin: true,
                },
            },
        },
        preview: {
            port: 4173,
        },
    };
});
