# okhttp optionally probes for Conscrypt at runtime; it is not bundled, so
# R8 must not treat the references as fatal (generated missing_rules fix).
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.OpenSSLProvider
