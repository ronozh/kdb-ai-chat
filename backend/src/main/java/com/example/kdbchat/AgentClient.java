package com.example.kdbchat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.time.Duration;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Forwards requests to the Python agent service. */
@Component
public class AgentClient {

    /** Agent unreachable or returned an error (mapped to 502). */
    public static class AgentException extends RuntimeException {
        public AgentException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    /** Agent did not answer in time (mapped to 504). */
    public static class AgentTimeoutException extends RuntimeException {
        public AgentTimeoutException(String message, Throwable cause) {
            super(message, cause);
        }
    }

    private final String baseUrl;
    private final String token;
    private final Duration timeout;
    private final ObjectMapper mapper;
    private final HttpClient http;

    public AgentClient(@Value("${agent.url}") String baseUrl,
                       @Value("${agent.token}") String token,
                       @Value("${agent.timeout-seconds}") long timeoutSeconds,
                       ObjectMapper mapper) {
        if (token.isBlank()) {
            throw new IllegalStateException("AGENT_TOKEN is not set (run: make secrets)");
        }
        this.baseUrl = baseUrl.replaceAll("/+$", "");
        this.token = token;
        this.timeout = Duration.ofSeconds(timeoutSeconds);
        this.mapper = mapper;
        // HTTP/1.1: the default h2c upgrade makes uvicorn drop the request body
        this.http = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofSeconds(5)).build();
    }

    public JsonNode chat(String sessionId, String userId, String role, String question) {
        Map<String, String> body = Map.of("session_id", sessionId, "user_id", userId, "role", role, "question", question);
        return send(HttpRequest.newBuilder(URI.create(baseUrl + "/chat"))
                .timeout(timeout)
                .header("Content-Type", "application/json")
                .header("X-Agent-Token", token)
                .POST(HttpRequest.BodyPublishers.ofString(write(body)))
                .build());
    }

    public JsonNode health() {
        return send(HttpRequest.newBuilder(URI.create(baseUrl + "/health")).timeout(Duration.ofSeconds(5)).GET().build());
    }

    private JsonNode send(HttpRequest request) {
        try {
            HttpResponse<String> resp = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() / 100 != 2) {
                throw new AgentException("agent returned " + resp.statusCode() + ": " + resp.body(), null);
            }
            return mapper.readTree(resp.body());
        } catch (JsonProcessingException e) {
            throw new AgentException("agent returned invalid JSON: " + e.getOriginalMessage(), e);
        } catch (HttpTimeoutException e) {
            throw new AgentTimeoutException("agent did not respond within " + timeout.toSeconds() + "s", e);
        } catch (IOException e) {
            throw new AgentException("agent unreachable at " + baseUrl + ": "
                    + (e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName()), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new AgentException("interrupted", e);
        }
    }

    private String write(Object value) {
        try {
            return mapper.writeValueAsString(value);
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }
}
