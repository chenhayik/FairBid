plugins {
    java
    id("org.springframework.boot") version "4.0.3"
    id("io.spring.dependency-management") version "1.1.7"
}

group = "com.marketplace"
version = "0.0.1-SNAPSHOT"
description = "user-profile-service"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

repositories {
    mavenCentral()
}



dependencies {
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-security")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-webmvc")
    runtimeOnly("org.postgresql:postgresql")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.security:spring-security-test")
    implementation("org.springframework.kafka:spring-kafka")

//
//    implementation("io.jsonwebtoken:jjwt-api")
//    runtimeOnly("io.jsonwebtoken:jjwt-impl")
//    runtimeOnly("io.jsonwebtoken:jjwt-jackson")

    // Your existing DB driver
    runtimeOnly("org.postgresql:postgresql")
//    testImplementation("org.springframework.boot:spring-boot-starter-webmvc-test")
//    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.withType<Test> {
    useJUnitPlatform()
}
