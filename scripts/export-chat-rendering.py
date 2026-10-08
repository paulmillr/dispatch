#!/usr/bin/env python3
"""Export existing chat rendering profiles using the Xcode that recorded them.

Run on the recording Mac. Accepts Profile ZIPs or .trace directories; writes a
portable XML ZIP without recording again, changing the input, or uploading data.
"""

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


EXTRA_SCHEMAS = {
    "runloop-events", "potential-hangs", "hang-risks", "thread-state",
    "thread-narrative", "time-profile", "device-display-info", "device-gpu-info",
    "device-thermal-state-intervals", "process-info", "thread-info", "time-info",
}


def relevant(schema):
    return schema.startswith(("hitches", "display-", "displayed-surfaces")) or schema in EXTRA_SCHEMAS


def run_export(trace, destination, selector):
    command = ["/usr/bin/xcrun", "xctrace", "export", "--input", str(trace),
               *selector, "--output", str(destination)]
    log = destination.with_suffix(".log")
    try:
        with log.open("w") as stream:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            return f"exit {result.returncode}: {log.read_text().strip()[-1500:]}"
        if not destination.is_file():
            return "xctrace produced no XML file"
        return None
    except subprocess.TimeoutExpired:
        return "export timed out after 300 seconds"


def prepare_input(source, scratch, output):
    if source.is_dir() and source.suffix == ".trace":
        return source
    if not zipfile.is_zipfile(source):
        raise ValueError("expected a Profile ZIP or .trace directory")
    with zipfile.ZipFile(source) as archive:
        traces = set()
        for member in archive.infolist():
            parts = PurePosixPath(member.filename).parts
            if "__MACOSX" in parts or any(p.startswith("._") for p in parts):
                continue
            if "rendering.trace" not in parts:
                continue
            index = parts.index("rendering.trace")
            traces.add(parts[:index + 1])
        if len(traces) != 1:
            raise ValueError(f"expected one rendering.trace, found {len(traces)}")
        prefix = next(iter(traces))
        trace = scratch / "rendering.trace"
        trace.mkdir()
        for member in archive.infolist():
            parts = PurePosixPath(member.filename).parts
            if parts[:len(prefix)] != prefix:
                continue
            relative = parts[len(prefix):]
            if not relative or any(p.startswith("._") for p in relative):
                continue
            if ".." in relative or PurePosixPath(*relative).is_absolute():
                raise ValueError("unsafe archive path")
            destination = trace.joinpath(*relative)
            if member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as src, destination.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
        for name in ("report.json", "README.txt", "rendering.log"):
            archived = str(PurePosixPath(*prefix[:-1], name))
            if archived in archive.namelist():
                (output / name).write_bytes(archive.read(archived))
        return trace


def export_profile(source, output):
    output.mkdir()
    manifest = {"source": source.name, "tables": [], "errors": []}
    try:
        with tempfile.TemporaryDirectory(prefix="dispatch-trace-export-") as temporary:
            trace = prepare_input(source, Path(temporary), output)
            error = run_export(trace, output / "toc.xml", ["--toc"])
            if error:
                raise ValueError(f"Cannot read trace: {error}. Use the recording Mac's Xcode or a newer version.")
            toc = ET.parse(output / "toc.xml")
            for run in toc.getroot().findall("run"):
                number = run.get("number")
                if not number or not number.isdigit():
                    raise ValueError("invalid run number in trace table of contents")
                for index, table in enumerate(run.findall("data/table"), 1):
                    schema = table.get("schema", "")
                    if not relevant(schema):
                        continue
                    # Select by position: schemas can repeat with different parameters.
                    filename = f"run-{number}-table-{index}.xml"
                    print(f"  {source.name}: {schema}", flush=True)
                    error = run_export(trace, output / filename, [
                        "--xpath", f'/trace-toc/run[@number="{number}"]/data/table[{index}]'])
                    record = {"schema": schema, "file": filename}
                    if not error:
                        try:
                            rows = 0
                            # Keep the original IDs/references and full schema in XML.
                            for _, element in ET.iterparse(output / filename, events=("end",)):
                                if element.tag == "row":
                                    rows += 1
                                element.clear()
                            record["rows"] = rows
                        except ET.ParseError as exception:
                            error = f"invalid XML: {exception}"
                    if error:
                        record["error"] = error
                        manifest["errors"].append(f"{schema}: {error}")
                    manifest["tables"].append(record)
            if not manifest["tables"]:
                raise ValueError("no rendering tables found in the trace")
    except (OSError, ValueError, ET.ParseError, zipfile.BadZipFile) as exception:
        manifest["errors"].append(str(exception))
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", nargs="+", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("tmp"))
    args = parser.parse_args()
    sources = [path.expanduser().resolve() for path in args.profiles]
    if any(not path.exists() for path in sources):
        parser.error("all input profiles must exist")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="chat-rendering-export-", dir=args.output_dir.resolve()))
    with (output / "xcode-version.txt").open("w") as stream:
        subprocess.run(["/usr/bin/xcodebuild", "-version"], stdout=stream, stderr=subprocess.STDOUT)
    print(f"Exporting existing recordings to {output}; this can take several minutes.", flush=True)
    failures = []
    for index, source in enumerate(sources, 1):
        manifest = export_profile(source, output / f"{index}-{source.stem}")
        failures.extend(f"{source.name}: {error}" for error in manifest["errors"])
    archive = shutil.make_archive(str(output), "zip", output.parent, output.name)
    print(f"\nExport ZIP: {archive}", flush=True)
    if failures:
        print("Some exports failed; the ZIP includes logs:\n" + "\n".join(failures), flush=True)
        return 1
    print("Export complete. Share this ZIP for analysis. Nothing was uploaded.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
