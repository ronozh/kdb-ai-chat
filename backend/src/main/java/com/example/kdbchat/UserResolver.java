package com.example.kdbchat;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Map;
import java.util.Optional;
import org.springframework.stereotype.Component;

/**
 * Who is calling, and which user group they belong to. The agent maps each group to the tables it may query
 * (agent/groups.yaml). Demo stub: trusts the X-Demo-User header. Replace with real authentication (SSO/login)
 * here; nothing else changes.
 */
@Component
public class UserResolver {

    public record Caller(String user, String group) {}

    static final String HEADER = "X-Demo-User";

    /** User -> group. */
    static final Map<String, String> GROUPS = Map.of(
            "alice", "research",  // daily_prices
            "bob", "trading",     // trades, quotes
            "carol", "all");      // every table

    /** Empty when the user is unknown: the caller gets 403, never a default group. */
    public Optional<Caller> resolve(HttpServletRequest request) {
        String user = request.getHeader(HEADER);
        if (user == null) {
            return Optional.empty();
        }
        String group = GROUPS.get(user.trim());
        return group == null ? Optional.empty() : Optional.of(new Caller(user.trim(), group));
    }
}
