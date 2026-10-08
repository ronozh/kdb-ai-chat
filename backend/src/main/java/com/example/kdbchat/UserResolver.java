package com.example.kdbchat;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import java.util.Optional;
import org.springframework.stereotype.Component;

/**
 * Who is calling, and which read-only data role they get.
 * Demo stub: trusts the X-Demo-User header. Replace with real authentication (SSO/login) here; nothing else changes.
 */
@Component
public class UserResolver {

    public record Caller(String user, String role) {}

    static final String HEADER = "X-Demo-User";

    /** User -> role. Each role maps to one kdb read-only user that can only see one table. */
    static final Map<String, String> ROLES = Map.of(
            "alice", "prices",   // daily_prices
            "bob", "trades",     // trades
            "carol", "quotes");  // quotes

    /** Empty when the user is unknown: the caller gets 403, never a default role. */
    public Optional<Caller> resolve(HttpServletRequest request) {
        String user = request.getHeader(HEADER);
        if (user == null) {
            return Optional.empty();
        }
        String role = ROLES.get(user.trim());
        return role == null ? Optional.empty() : Optional.of(new Caller(user.trim(), role));
    }
}
