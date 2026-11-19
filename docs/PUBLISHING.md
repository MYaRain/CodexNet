# Publishing this repository to GitHub

The working copy is the `codex-net` folder that contains this `docs/` directory.

`git` is **not installed** on this machine yet, so pick one of the two paths below.

---

## Before anything: the privacy checklist

1. `profiles.json` must **not** be committed — it contains absolute paths from your machine. It is
   already listed in `.gitignore`.
2. `LOCAL-NOTES.md` (your machine-specific findings) is git-ignored as well.
3. `*.lnk` shortcuts are machine-specific and git-ignored.
4. Confirm no other file contains a home directory path or the name of your proxy client:

   ```powershell
   Select-String -Path *.md,*.ps1,*.json,*.cmd -Pattern 'C:\\Users\\'
   ```

   `CodexNet-GUI.ps1` and `Start-CodexNet.ps1` only resolve paths at runtime, so a clean result is expected.

5. `LICENSE` must be the first thing a visitor can see — keep it at the repository root.

---

## Path A — no git, upload through the browser (fastest)

1. On GitHub: **New repository**.
   * Name: `codexnet`
   * Description: `Pin a Windows app to one proxy: Chromium flag + env vars + optional per-exe firewall lock. No driver, no TUN, MIT.`
   * Visibility: public
   * Do **not** add a README, .gitignore or license — they already exist here.
2. In the empty repository click **uploading an existing file**.
3. Drag in everything **except** `profiles.json`, `LOCAL-NOTES.md` and the two `.lnk` files.
   Directory structure (`docs/`, `examples/`) is preserved by the drag-and-drop uploader.
4. Commit message: `Initial release: v0.1.0 — per-app proxy binding for Windows`
5. After the upload: **Settings → General → Topics**, add
   `windows proxy per-app proxifier powershell firewall clash electron mit`.
6. **Releases → Draft a new release**, tag `v0.1.0`, attach a zip of the folder if you want a
   one-click download.

## Path B — install git, then a normal first commit

```powershell
winget install --id Git.Git -e
# reopen the terminal so PATH is refreshed

cd <path-to>\codex-net
git init -b main
git add .
git status                 # verify profiles.json / *.lnk are NOT staged
git commit -m "Initial release: v0.1.0 - per-app proxy binding for Windows"
git remote add origin https://github.com/<your-name>/codexnet.git
git push -u origin main
```

If `git commit` complains about identity:

```powershell
git config --global user.name  "<your name>"
git config --global user.email "<your email>"
```

---

## Suggested repository metadata

| Field | Value |
| --- | --- |
| Name | `codexnet` |
| About | `Pin a Windows app to one proxy: Chromium flag + env vars + optional per-exe firewall lock. No driver, no TUN, MIT.` |
| Topics | `windows`, `proxy`, `per-app`, `proxifier`, `powershell`, `firewall`, `clash`, `electron`, `mit` |
| License | MIT (GitHub detects it from `LICENSE`) |
| Release tag | `v0.1.0` |

## After publishing

* Add a screenshot of the GUI to the README — a visual is worth more than three paragraphs for a
  desktop tool. (Not included here because it must come from your own desktop.)
* Open the first issue yourself to seed the tracker: "Apps that ignore proxy settings — what to do".
* If you rename the project, rename the script files to match; the `.vbs` and `.cmd` launchers resolve
  their siblings by folder, so only the file names need updating.
