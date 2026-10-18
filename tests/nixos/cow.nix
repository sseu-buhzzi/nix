{
  lib,
  config,
  nixpkgs,
  pkgs,
  ...
}:

{
  name = "cow";

  nodes.machine =
    { pkgs, ... }:
    {
      # A scratch disk that we format as btrfs, which supports reflinks.
      virtualisation.emptyDiskImages = [ 1024 ];
      boot.supportedFilesystems = [ "btrfs" ];
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      nix.settings.require-sigs = false;
      # `filefrag` (e2fsprogs) reports the `shared` extent flag set by reflinks.
      environment.systemPackages = [ pkgs.btrfs-progs pkgs.e2fsprogs ];
    };

  testScript =
    { nodes }:
    ''
      import json

      # Must be larger than the 64 KiB copy buffer used by `copyFdRange()`;
      # otherwise the CoW fast path is not eligible and a regular buffered
      # copy is used.
      srcFile = "big"

      machine.wait_for_unit("multi-user.target")

      machine.succeed("mkfs.btrfs -f /dev/vdb")
      machine.succeed("mkdir -p /mnt")
      machine.succeed("mount -t btrfs /dev/vdb /mnt")

      # A source tree on the btrfs volume.
      machine.succeed("mkdir -p /mnt/src")
      machine.succeed(f"dd if=/dev/urandom of=/mnt/src/{srcFile} bs=1M count=1 status=none")

      def sh(command):
          # Run `command` and log its output, so the raw evidence (e.g. the
          # `filefrag` extents) shows up in the test log.
          output = machine.succeed(command)
          machine.log(f"$ {command}\n{output}")
          return output

      def is_shared(path):
          # A reflinked file shares its extents with the original, which
          # `filefrag` reports with the `shared` flag.
          machine.succeed("sync")
          return "shared" in sh(f"filefrag -v {path}")

      def nar_hash(store, path):
          name = path.rsplit("/", 1)[-1]
          out = machine.succeed(f"nix --store {store} path-info --json --json-format 2 {path}")
          return json.loads(out)["info"][name]["narHash"]

      # ------------------------------------------------------------------
      # P1: `nix store add-path` with the source and the store on the same
      # btrfs volume -> a reflink must have happened.
      # ------------------------------------------------------------------
      machine.log("P1: `nix store add-path` on the same btrfs volume (expect reflink)")
      p1 = machine.succeed("nix --store /mnt/store-a store add-path --name cow-p1 /mnt/src").strip()
      name1 = p1.rsplit("/", 1)[-1]
      aFile = f"/mnt/store-a/nix/store/{name1}/{srcFile}"
      assert is_shared(aFile), "P1 did not reflink (see `filefrag -v` above)"
      sh(f"nix --store /mnt/store-a store verify {p1}")

      # ------------------------------------------------------------------
      # P4: `nix copy` between two stores on the same btrfs volume -> the
      # destination must be reflinked and hold the same content.
      # ------------------------------------------------------------------
      machine.log("P4: `nix copy` between two stores on the same btrfs volume (expect reflink)")
      machine.succeed(f"nix --store /mnt/store-a copy --no-check-sigs --to /mnt/store-b {p1}")
      bFile = f"/mnt/store-b/nix/store/{name1}/{srcFile}"
      assert is_shared(bFile), "P4 did not reflink (see `filefrag -v` above)"
      sh(f"nix --store /mnt/store-b store verify {p1}")
      hashA = nar_hash("/mnt/store-a", p1)
      hashB = nar_hash("/mnt/store-b", p1)
      machine.log(f"P4 narHash store-a: {hashA}")
      machine.log(f"P4 narHash store-b: {hashB}")
      assert hashA == hashB, "P4 narHash mismatch"

      # ------------------------------------------------------------------
      # P3: a `path:` input (libfetchers) with the source and the store on the
      # same btrfs volume -> `Store::addToStore("source", ...)` must reflink.
      # ------------------------------------------------------------------
      machine.log("P3: `path:` input on the same btrfs volume (expect reflink)")
      machine.succeed("mkdir -p /mnt/src3")
      machine.succeed(f"dd if=/dev/urandom of=/mnt/src3/{srcFile} bs=1M count=1 status=none")
      p3 = sh(
          "nix --store /mnt/store-a eval --impure --raw "
          "--expr '(builtins.fetchTree \"path:///mnt/src3\").outPath'"
      ).strip()
      machine.log(f"P3 outPath: {p3}")
      # `outPath` is a logical store path; the store is rooted at
      # `/mnt/store-a`, so the real file lives under `/mnt/store-a/nix/store`.
      name3 = p3.rsplit("/", 1)[-1]
      aFile3 = f"/mnt/store-a/nix/store/{name3}/{srcFile}"
      exists3 = sh(f"test -e {aFile3} && echo yes").strip()
      assert exists3 == "yes", f"P3 path: input did not land in store-a (outPath={p3})"
      assert is_shared(aFile3), "P3 path: input did not reflink (see `filefrag -v` above)"
      sh(f"nix --store /mnt/store-a store verify {p3}")

      # ------------------------------------------------------------------
      # Cross-device fallback: the source is on the (ext4) root file system
      # while the store is on btrfs, so `canCopyPathCoW()` must refuse and
      # the import must fall back to the NAR path (a real copy).
      # ------------------------------------------------------------------
      machine.log("Cross-device fallback: ext4 source -> btrfs store (expect no reflink)")
      machine.succeed("mkdir -p /root/cow-src")
      machine.succeed(f"dd if=/dev/urandom of=/root/cow-src/{srcFile} bs=1M count=1 status=none")
      p2 = machine.succeed("nix --store /mnt/store-c store add-path --name cow-p2 /root/cow-src").strip()
      name2 = p2.rsplit("/", 1)[-1]
      cFile = f"/mnt/store-c/nix/store/{name2}/{srcFile}"
      assert not is_shared(cFile), "cross-device import must not reflink"
      sh(f"nix --store /mnt/store-c store verify {p2}")
    '';
}
