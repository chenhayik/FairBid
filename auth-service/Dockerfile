FROM gradle:9.3.1-jdk25 AS builder

WORKDIR /app

COPY gradlew .
COPY gradle gradle/
COPY build.gradle.kts .
COPY settings.gradle.kts .
COPY auth-service auth-service/

RUN ./gradlew :auth-service:bootJar -x test --no-daemon

# ─── STAGE 2: RUN ────────────────────────────────────────────
FROM eclipse-temurin:25-jre-alpine

WORKDIR /app

# Temporary - find the jar location
RUN find /app -name "*.jar" -type f

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

COPY --from=builder /app/auth-service/build/libs/auth-service.jar app.jar

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:8081/actuator/health || exit 1

EXPOSE 8081

ENTRYPOINT ["java", "-Dspring.threads.virtual.enabled=true", "-jar", "app.jar"]