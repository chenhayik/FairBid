package com.marketplace.authservice.service;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import javax.crypto.SecretKey; // New standard for 0.12+
import java.nio.charset.StandardCharsets;
import java.util.Date;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.Map;
import java.util.UUID;

@Service
public class JwtService {

    // Set these in application.yml — never hardcode secrets
    @Value("${jwt.secret}")
    private String jwtSecret;

    @Value("${jwt.access-token-expiry-ms}")
    private long accessTokenExpiryMs;   // 900000 = 15 minutes

    @Value("${jwt.refresh-token-expiry-ms}")
    private long refreshTokenExpiryMs;  // 2592000000 = 30 days

    private SecretKey getSigningKey() {
        return Keys.hmacShaKeyFor(jwtSecret.getBytes(StandardCharsets.UTF_8));
    }

    public String generateAccessToken(UUID userId, String email, String role) {
        return Jwts.builder()
                .subject(email)
                .claims(Map.of(
                        "userId", userId.toString(),
                        "role",   role,
                        "type",   "access"
                ))
                .issuedAt(new Date())
                .expiration(new Date(System.currentTimeMillis() + accessTokenExpiryMs))
                .signWith(getSigningKey())
                .compact();
    }

    public String generateRefreshToken(UUID userId, String email) {
        return Jwts.builder()
                .subject(email)
                .claims(Map.of(
                        "userId", userId.toString(),
                        "type",   "refresh"
                ))
                .issuedAt(new Date())
                .expiration(new Date(System.currentTimeMillis() + refreshTokenExpiryMs))
                .signWith(getSigningKey())
                .compact();
    }

    public Claims extractAllClaims(String token) {
        return Jwts.parser()
                .verifyWith(getSigningKey())
                .build()
                .parseSignedClaims(token)
                .getPayload();
    }

    public String extractEmail(String token) {
        return extractAllClaims(token).getSubject();
    }

    public boolean isTokenValid(String token) {
        try {
            return extractAllClaims(token)
                    .getExpiration()
                    .after(new Date());
        } catch (Exception e) {
            return false;
        }
    }
}