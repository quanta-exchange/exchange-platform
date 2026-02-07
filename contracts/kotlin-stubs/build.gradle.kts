plugins {
    kotlin("jvm") version "1.9.25"
}

group = "com.quanta.exchange"
version = "0.1.0"

kotlin {
    jvmToolchain(21)
}

sourceSets {
    main {
        java.srcDirs("../gen/kotlin/java")
    }
}

dependencies {
    implementation(kotlin("stdlib"))
    implementation("com.google.protobuf:protobuf-java:4.33.5")
    implementation("io.grpc:grpc-protobuf:1.78.0")
    implementation("io.grpc:grpc-stub:1.78.0")
    implementation("javax.annotation:javax.annotation-api:1.3.2")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
