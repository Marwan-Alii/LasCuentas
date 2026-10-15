// Versions below were chosen from memory of stable releases and could NOT be resolved in the authoring sandbox
// (Google Maven / Gradle servers were unreachable). If Gradle reports a missing version, bump to the nearest stable one.
plugins {
    id("com.android.application") version "8.7.2" apply false
    kotlin("android") version "2.0.21" apply false
    kotlin("plugin.compose") version "2.0.21" apply false
    kotlin("plugin.serialization") version "2.0.21" apply false
}
