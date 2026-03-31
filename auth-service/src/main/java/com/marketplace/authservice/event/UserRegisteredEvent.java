package com.marketplace.authservice.event;

public record UserRegisteredEvent(
        String userId,
        String email,
        com.marketplace.authservice.model.Role role
) {}