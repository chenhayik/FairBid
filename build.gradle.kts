plugins {
    java
    id("org.springframework.boot") version "4.0.3" apply false // Only apply at subproject level
    id("io.spring.dependency-management") version "1.1.7"
}

group = "com.marketplace"
version = "0.0.1-SNAPSHOT"

subprojects {
    apply(plugin = "java")
    apply(plugin = "org.springframework.boot") // Crucial for starter resolution
    apply(plugin = "io.spring.dependency-management")

    java {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(25))
        }
    }

    repositories {
        mavenCentral()
    }


    tasks.getByName<org.springframework.boot.gradle.tasks.bundling.BootJar>("bootJar") {
        enabled = true // Ensures the executable jar is always built
    }
    layout.buildDirectory.set(layout.projectDirectory.dir("build"))

    tasks.withType<org.springframework.boot.gradle.tasks.bundling.BootJar> {
        // Explicitly set the destination so you always know where it is
        destinationDirectory.set(layout.buildDirectory.dir("libs"))
        archiveFileName.set("${project.name}.jar") // This makes it always 'auth-service.jar'
    }

    dependencyManagement {
        imports {
            mavenBom("org.springframework.boot:spring-boot-dependencies:4.0.3")
            mavenBom("org.springframework.cloud:spring-cloud-dependencies:2025.1.1")
            // Add the JJWT BOM here
            mavenBom("io.jsonwebtoken:jjwt-bom:0.13.0")
        }
    }

    dependencies {
        // Lombok - standard setup
        compileOnly("org.projectlombok:lombok")
        annotationProcessor("org.projectlombok:lombok")
        testCompileOnly("org.projectlombok:lombok")
        testAnnotationProcessor("org.projectlombok:lombok")

        implementation("org.springframework.boot:spring-boot-starter-web")
        testImplementation("org.springframework.boot:spring-boot-starter-test")
    }

    dependencyManagement {
        imports {
            mavenBom("org.springframework.boot:spring-boot-dependencies:4.0.3")
            mavenBom("org.springframework.cloud:spring-cloud-dependencies:2025.1.1")
        }
    }

    // Disable the executable jar task for the root and shared libs (optional but cleaner)
    tasks.getByName<org.springframework.boot.gradle.tasks.bundling.BootJar>("bootJar") {
        enabled = true
    }
}