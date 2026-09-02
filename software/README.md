# software/

Drop the Cisco downloads here. Nothing in this folder is committed. The
`.gitignore` beside this file ignores everything except itself and this
README, and the repo root `.gitignore` also blocks `*.iso`, `*.pkg`, and
`*.qcow2` everywhere as a second guard.

Expected contents:

```
software/
├── cml2_2.9.x_amd64-N.pkg          CML update package, about 1 GB
├── refplat-YYYYMMDD-fcs.iso        reference platform images, 15 to 40 GB
├── refplat-YYYYMMDD-fcs.iso.signature
└── refplat-YYYYMMDD-fcs.iso.README
```

Keep the files as downloaded. Do not extract the ISO. The upload script mounts
it read-only, copies the package plus only the node definitions and images the
scenarios need into the `cml` blob container, and unmounts. Nothing is
written back here.

Scripts find this folder through `CML_SOFTWARE_DIR`, default
`<repo root>/software`.

OneDrive note: this repo lives under OneDrive, so large files here get synced.
If OneDrive turns one into an on-demand placeholder, right-click it in Finder
and choose "Always Keep on This Device" before running the upload script.
