# Suppress warnings about optional classes referenced by smb/mbassador libraries
-dontwarn javax.el.**
-dontwarn org.ietf.jgss.**
-dontwarn net.engio.mbassy.**
-dontwarn com.hierynomus.**

# Keep the main classes so they don't get removed if used reflectively
-keep class net.engio.mbassy.** { *; }
-keep class com.hierynomus.** { *; }
-keep class org.videolan.libvlc.** { *; }

# Keep SLF4J bindings if present
-dontwarn org.slf4j.**

# If you still see missing classes listed in build output, add them to -dontwarn
# or include the required library on the classpath if you need that functionality.
