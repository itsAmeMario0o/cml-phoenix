# software/

Drop the Cisco downloads here. Nothing in this folder is ever committed.
The `.gitignore` beside this file ignores everything except itself and this
README, and the root `.gitignore` blocks `*.iso`, `*.pkg`, and `*.qcow2`
everywhere as a second guard.

What belongs here:

```
software/
├── cml2_2.9.x_amd64-N.pkg          CML update package, about 1 GB
├── refplat-YYYYMMDD-fcs.iso        reference platform images, 15 to 40 GB
├── refplat-YYYYMMDD-fcs.iso.signature
└── refplat-YYYYMMDD-fcs.iso.README
```

Keep the files as downloaded and do not extract the ISO. The upload script
mounts it read-only, copies the package plus only the node definitions and
images the scenarios need into the `cml` blob container, and unmounts.
Nothing is written back here.

Scripts find this folder through `CML_SOFTWARE_DIR`, which defaults to
`<repo root>/software`.

One OneDrive caveat. This repo lives under OneDrive, so a large ISO here
will sync. If OneDrive later swaps it for an on-demand placeholder, right
click the file in Finder and choose "Always Keep on This Device" before
running the upload script, or the mount will fail with a short read.
