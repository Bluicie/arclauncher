import 'package:flauncher/providers/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("isAbiSplitApk", () {
    test("detects ABI-split release assets", () {
      expect(isAbiSplitApk("arclauncher-1.0.5-arm64-v8a.apk"), isTrue);
      expect(isAbiSplitApk("arclauncher-1.0.5-armeabi-v7a.apk"), isTrue);
      expect(isAbiSplitApk("arclauncher-1.0.5-x86_64.apk"), isTrue);
      expect(isAbiSplitApk("arclauncher-1.0.5-x86.apk"), isTrue);
    });

    test("treats universal assets as non-split", () {
      expect(isAbiSplitApk("arclauncher-1.0.5.apk"), isFalse);
      expect(isAbiSplitApk("arclauncher.apk"), isFalse);
      expect(isAbiSplitApk("arc-launcher-universal-release.apk"), isFalse);
    });
  });

  group("pickReleaseApk", () {
    test("prefers universal APK over ABI splits", () {
      final picked = pickReleaseApk([
        {
          "name": "arclauncher-1.0.5-arm64-v8a.apk",
          "browser_download_url": "https://example.com/arm64.apk",
        },
        {
          "name": "arclauncher-1.0.5-armeabi-v7a.apk",
          "browser_download_url": "https://example.com/armeabi.apk",
        },
        {
          "name": "arclauncher-1.0.5.apk",
          "browser_download_url": "https://example.com/universal.apk",
        },
      ]);

      expect(picked?.name, "arclauncher-1.0.5.apk");
      expect(picked?.url, "https://example.com/universal.apk");
    });

    // The release workflow publishes the universal APK twice: version-stamped
    // (`arclauncher-<tag>.apk`) and as the stable `arclauncher.apk` alias for
    // TV box Downloader codes. The GitHub API returns assets in ASCII name
    // order, where '-' (0x2D) sorts before '.' (0x2E). That puts the ABI
    // splits ahead of the version-stamped universal, and the version-stamped
    // universal ahead of the alias. The fixture below mirrors that real
    // response order; the version-stamped universal is what we must keep
    // resolving so self-updates keep a versioned filename.
    test("prefers the version-stamped universal over the stable alias", () {
      final picked = pickReleaseApk([
        {
          "name": "arclauncher-1.0.10-arm64-v8a.apk",
          "browser_download_url": "https://example.com/arm64.apk",
        },
        {
          "name": "arclauncher-1.0.10-armeabi-v7a.apk",
          "browser_download_url": "https://example.com/armeabi.apk",
        },
        {
          "name": "arclauncher-1.0.10.apk",
          "browser_download_url": "https://example.com/versioned.apk",
        },
        {
          "name": "arclauncher.apk",
          "browser_download_url": "https://example.com/alias.apk",
        },
      ]);

      expect(picked?.name, "arclauncher-1.0.10.apk");
      expect(picked?.url, "https://example.com/versioned.apk");
    });

    // If the API ever stops sorting by name, the alias is picked instead. It is
    // byte-identical to the version-stamped universal, so the update still
    // installs; this pins that we degrade to a working APK rather than a split.
    test("still resolves a valid universal if the alias sorts first", () {
      final picked = pickReleaseApk([
        {
          "name": "arclauncher.apk",
          "browser_download_url": "https://example.com/alias.apk",
        },
        {
          "name": "arclauncher-1.0.10-arm64-v8a.apk",
          "browser_download_url": "https://example.com/arm64.apk",
        },
        {
          "name": "arclauncher-1.0.10-armeabi-v7a.apk",
          "browser_download_url": "https://example.com/armeabi.apk",
        },
        {
          "name": "arclauncher-1.0.10.apk",
          "browser_download_url": "https://example.com/versioned.apk",
        },
      ]);

      expect(picked?.name, "arclauncher.apk");
      expect(isAbiSplitApk(picked!.name), isFalse);
    });

    test("falls back to first APK when no universal exists", () {
      final picked = pickReleaseApk([
        {
          "name": "arclauncher-1.0.5-arm64-v8a.apk",
          "browser_download_url": "https://example.com/arm64.apk",
        },
        {
          "name": "arclauncher-1.0.5-armeabi-v7a.apk",
          "browser_download_url": "https://example.com/armeabi.apk",
        },
      ]);

      expect(picked?.name, "arclauncher-1.0.5-arm64-v8a.apk");
    });
  });
}
