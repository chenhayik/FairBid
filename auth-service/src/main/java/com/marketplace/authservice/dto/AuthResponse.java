package com.marketplace.authservice.dto;

import com.marketplace.authservice.model.Role;
import java.util.UUID;

// What gets sent back to the client after login or register
public record AuthResponse(
        UUID    userId,
        String  name,
        String  email,
        Role    role,
        String  accessToken,   // short-lived  — 15 minutes
        String  refreshToken   // long-lived   — 30 days
) {}