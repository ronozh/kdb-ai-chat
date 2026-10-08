package com.example.kdbchat;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class ChatController {

    public record ChatRequest(String session_id, String question) {}

    static final int MAX_QUESTION_LENGTH = 2000;

    private final AgentClient agent;
    private final UserResolver users;

    public ChatController(AgentClient agent, UserResolver users) {
        this.agent = agent;
        this.users = users;
    }

    @PostMapping("/chat")
    public ResponseEntity<?> chat(@RequestBody ChatRequest req, HttpServletRequest http) {
        if (req.question() == null || req.question().isBlank()) {
            return error(HttpStatus.BAD_REQUEST, "question is required");
        }
        if (req.question().length() > MAX_QUESTION_LENGTH) {
            return error(HttpStatus.BAD_REQUEST, "question is longer than " + MAX_QUESTION_LENGTH + " characters");
        }
        String sessionId = req.session_id() == null || req.session_id().isBlank()
                ? UUID.randomUUID().toString() : req.session_id();
        return ResponseEntity.ok(agent.chat(sessionId, users.currentUser(http), req.question()));
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("backend", "ok");
        try {
            JsonNode a = agent.health();
            out.put("agent", a);
            boolean ok = "ok".equals(a.path("status").asText());
            return ResponseEntity.status(ok ? HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE).body(out);
        } catch (RuntimeException e) {
            out.put("agent", Map.of("status", "down", "error", e.getMessage()));
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(out);
        }
    }

    @ExceptionHandler(AgentClient.AgentTimeoutException.class)
    public ResponseEntity<Map<String, String>> timeout(AgentClient.AgentTimeoutException e) {
        return error(HttpStatus.GATEWAY_TIMEOUT, e.getMessage());
    }

    @ExceptionHandler(AgentClient.AgentException.class)
    public ResponseEntity<Map<String, String>> agentError(AgentClient.AgentException e) {
        return error(HttpStatus.BAD_GATEWAY, e.getMessage());
    }

    private static ResponseEntity<Map<String, String>> error(HttpStatus status, String message) {
        return ResponseEntity.status(status).body(Map.of("error", message));
    }
}
