# BouncyCastle finds its algorithms (RSA, X.509, SHA256withRSA) by class
# name at run time; R8 would strip them and pairing for remote control fails
# with "no such algorithm: RSA for provider BC".
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# moonlight-common-c calls back into these classes from native code by name.
-keep class com.limelight.** { *; }
-dontwarn org.jcodec.**
-dontwarn javax.naming.**
