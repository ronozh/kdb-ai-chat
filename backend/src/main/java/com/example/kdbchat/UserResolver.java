package com.example.kdbchat;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Component;

/** Phase 1 identity stub: trusts the X-Demo-User header. Phase 2 replaces this with real authentication. */
@Component
public class UserResolver {

    static final String HEADER = "X-Demo-User";
    static final String DEFAULT_USER = "demo";

    public String currentUser(HttpServletRequest request) {
        String user = request.getHeader(HEADER);
        return user == null || user.isBlank() ? DEFAULT_USER : user.trim();
    }
}
