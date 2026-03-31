package com.marketplace.authservice.service;

import com.marketplace.authservice.dto.AuthResponse;
import com.marketplace.authservice.dto.LoginRequest;
import com.marketplace.authservice.dto.RegisterRequest;
import com.marketplace.authservice.event.UserEventPublisher;
import com.marketplace.authservice.event.UserRegisteredEvent;
import com.marketplace.authservice.model.User;
import com.marketplace.authservice.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserRepository  userRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtService      jwtService;
    private final UserEventPublisher eventPublisher;

    public AuthResponse register(RegisterRequest request) {

        // 1. Check email is not already taken
        if (userRepository.existsByEmail(request.email())) {
            throw new IllegalArgumentException("Email already registered");
        }

        // 2. Build and save the user — password is hashed, never stored plain
        User user = User.builder()
                .name(request.name())
                .email(request.email())
                .password(passwordEncoder.encode(request.password()))
                .role(request.role())
                .isActive(true)
                .build();

        User savedUser = userRepository.save(user);

        eventPublisher.publishUserRegistered(new UserRegisteredEvent(
                savedUser.getId().toString(),
                savedUser.getEmail(),
                savedUser.getRole()
        ));


        // 3. Issue tokens immediately — user is logged in after registering
        String accessToken  = jwtService.generateAccessToken(
                savedUser.getId(), savedUser.getEmail(), savedUser.getRole().name());
        String refreshToken = jwtService.generateRefreshToken(
                savedUser.getId(), savedUser.getEmail());

        // 4. TODO: publish UserRegistered event to Kafka here
        //    so User Profile Service creates the profile automatically
        //    kafkaTemplate.send("marketplace.user.registered", savedUser.getId().toString(), event);

        return new AuthResponse(
                savedUser.getId(),
                savedUser.getName(),
                savedUser.getEmail(),
                savedUser.getRole(),
                accessToken,
                refreshToken
        );
    }

    public AuthResponse login(LoginRequest request) {

        // 1. Look up the user by email
        User user = userRepository.findByEmail(request.email())
                .orElseThrow(() -> new BadCredentialsException("Invalid email or password"));

        // 2. Check account is active
        if (!user.getIsActive()) {
            throw new BadCredentialsException("Account is suspended");
        }

        // 3. Compare submitted password against stored bcrypt hash
        if (!passwordEncoder.matches(request.password(), user.getPassword())) {
            throw new BadCredentialsException("Invalid email or password");

            // Note: same message for both cases — don't reveal which is wrong
        }

        // 4. Issue new tokens
        String accessToken  = jwtService.generateAccessToken(
                user.getId(), user.getEmail(), user.getRole().name());
        String refreshToken = jwtService.generateRefreshToken(
                user.getId(), user.getEmail());

        return new AuthResponse(
                user.getId(),
                user.getName(),
                user.getEmail(),
                user.getRole(),
                accessToken,
                refreshToken
        );
    }
}