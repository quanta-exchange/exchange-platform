plugins {
    kotlin("jvm") version "1.9.25"
    application
}

group = "com.quanta.exchange"
version = "0.1.0"

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("com.quanta.exchange.ledger.ApplicationKt")
}

dependencies {
    implementation(kotlin("stdlib"))
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
