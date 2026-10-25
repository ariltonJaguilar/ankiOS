import csv
import hashlib
import json
import subprocess
from pathlib import Path


root = Path(__file__).resolve().parents[2]
manifests = (
    root / "AnkiOS/AnkiBackendBridge/Cargo.toml",
    root / "AnkiOS/FSRSBridge/Cargo.toml",
)
output_csv = root / "Tools/Legal/rust-crate-licenses.csv"
output_text = root / "AnkiOS/Resources/Licenses/RustCrateLicenses.txt"

packages_by_source = {}
for manifest in manifests:
    result = subprocess.run(
        ["cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(manifest)],
        check=True,
        capture_output=True,
        text=True,
    )
    for package in json.loads(result.stdout)["packages"]:
        if not package.get("source"):
            continue
        key = (package["source"], package["name"], package["version"])
        existing = packages_by_source.setdefault(key, package)
        existing.setdefault("lockfiles", set()).add(str(manifest.relative_to(root)))

packages = sorted(packages_by_source.values(), key=lambda package: (package["name"], package["version"], package["source"]))

with output_csv.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(("package", "version", "authors", "license", "source", "repository", "lockfiles"))
    for package in packages:
        writer.writerow((
            package["name"],
            package["version"],
            "; ".join(package.get("authors") or []),
            package.get("license") or "See package source",
            package["source"],
            package.get("repository") or "",
            ";".join(sorted(package["lockfiles"])),
        ))

license_documents = {}
packages_without_license_files = []
for package in packages:
    package_root = Path(package["manifest_path"]).parent
    candidates = []
    if package.get("license_file"):
        candidates.append(package_root / package["license_file"])
    candidates.extend(
        path for path in package_root.iterdir()
        if path.is_file() and path.name.lower().startswith(("license", "copying", "notice"))
    )
    seen_paths = set()
    package_files = []
    for path in candidates:
        if path in seen_paths or not path.is_file() or path.stat().st_size > 500_000:
            continue
        seen_paths.add(path)
        content = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        content = b"\n".join(line.rstrip(b" \t") for line in content.split(b"\n"))
        try:
            content.decode("utf-8")
        except UnicodeDecodeError:
            continue
        digest = hashlib.sha256(content).hexdigest()
        license_documents.setdefault(digest, {"content": content, "packages": []})["packages"].append(
            f"{package['name']} {package['version']} ({package.get('license') or 'license in package source'})"
        )
        package_files.append(path)
    if not package_files:
        packages_without_license_files.append(package)

with output_text.open("w", encoding="utf-8") as handle:
    handle.write("Licenças das dependências Rust do AnkiOS\n")
    handle.write("\nInventário gerado a partir dos Cargo.lock de AnkiOS/AnkiBackendBridge e AnkiOS/FSRSBridge. Inclui dependências específicas de outras plataformas e ferramentas de compilação registradas nos grafos Rust; nem todos os pacotes listados entram no binário iOS. As versões, expressões de licença, origem e manifesto de cada pacote estão em Tools/Legal/rust-crate-licenses.csv.\n")
    handle.write("\nPacotes sem arquivo de licença publicado dentro do pacote estão identificados pela expressão SPDX e pelo repositório no CSV.\n")
    handle.write("\nTextos de licença publicados pelos pacotes:\n")
    for digest, document in sorted(license_documents.items()):
        handle.write("\n" + "=" * 78 + "\n")
        handle.write("Pacotes: " + "; ".join(sorted(set(document["packages"]))) + "\n")
        handle.write("SHA-256 do texto: " + digest + "\n\n")
        handle.write(document["content"].decode("utf-8"))
        if not document["content"].endswith(b"\n"):
            handle.write("\n")
    handle.write("\n" + "=" * 78 + "\nPacotes cuja distribuição não inclui um arquivo de licença:\n")
    for package in packages_without_license_files:
        handle.write(
            f"{package['name']} {package['version']} — {', '.join(package.get('authors') or ['authors not declared'])} — {package.get('license') or 'See package source'} — {package.get('repository') or package['source']}\n"
        )
