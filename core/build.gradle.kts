plugins { kotlin("jvm") version "2.0.21" }

kotlin { jvmToolchain(17) }

dependencies { testImplementation(kotlin("test")) }

tasks.test { useJUnitPlatform() }
