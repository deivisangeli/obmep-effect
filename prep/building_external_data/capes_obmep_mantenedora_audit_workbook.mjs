import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [jsonPath, outputPath, previewDir, coIesVersion = "base"] = process.argv.slice(2);
if (!jsonPath || !outputPath || !previewDir) {
  throw new Error("Usage: node builder.mjs sample.json output.xlsx preview_dir [base|regex_v1]");
}
const measured = {
  base: {
    pairs: 153786, people: 138368, users: 144860,
    mscOnly: 115835, phdOnly: 8799, both: 29152,
    placeboPeople: 6772,
    sourceDir: "capes_obmep_match_union_degree_duration_mantenedora",
  },
  regex_v1: {
    pairs: 172444, people: 154729, users: 162360,
    mscOnly: 129051, phdOnly: 8745, both: 34648,
    placeboPeople: 7649,
    sourceDir: "capes_obmep_match_union_degree_duration_mantenedora_regex_v1",
  },
};
if (!(coIesVersion in measured)) {
  throw new Error(`Unknown CO_IES version: ${coIesVersion}`);
}
const stats = measured[coIesVersion];

const rows = JSON.parse(await fs.readFile(jsonPath, "utf8"));
if (!Array.isArray(rows) || rows.length !== 100) {
  throw new Error(`Expected 100 sampled rows, received ${rows?.length}`);
}
const headers = Object.keys(rows[0]);
if (headers.length !== 44 || headers.at(-2) !== "verdict") {
  throw new Error(`Unexpected audit schema: ${headers.length} columns`);
}

const wb = Workbook.create();
const summary = wb.worksheets.add("Summary");
const audit = wb.worksheets.add("Audit sample");
const font = "Arial";
const navy = "#17365D";
const blue = "#1F4E78";
const orange = "#9E480E";
const green = "#375623";
const gray = "#44546A";
const lightBlue = "#D9EAF7";
const lightOrange = "#FCE4D6";
const lightGreen = "#E2F0D9";
const lightGray = "#E7E6E6";

for (const sheet of [summary, audit]) sheet.showGridLines = false;
summary.tabColor = navy;
audit.tabColor = blue;

summary.getRange("A2:H2").merge();
summary.getRange("A2").values = [[
  `CAPES × LinkedIn — CO_MANTENEDORA match audit (${coIesVersion})`,
]];
summary.getRange("A2:H2").format = {
  font: { name: font, size: 15, bold: true, color: navy },
  verticalAlignment: "center",
};
summary.getRange("A3:H3").format.borders = {
  bottom: { style: "thin", color: "#9EADBA" },
};
summary.getRange("A4:H4").merge();
summary.getRange("A4").values = [[
  "Latest degree_duration cohort; CAPES birth year ≥ 1988. Master’s and PhD institutions are matched independently. Institution key = M:<CO_MANTENEDORA>, with I:<CO_IES> fallback.",
]];
summary.getRange("A4:H4").format = {
  font: { name: font, size: 10, italic: true, color: "#595959" },
  wrapText: true,
};
summary.getRange("A4:H4").format.rowHeight = 34;

summary.getRange("A6:B6").values = [["Production result", "Value"]];
summary.getRange("A7:B14").values = [
  ["Deduplicated candidate pairs", stats.pairs],
  ["CAPES people with ≥1 pair", stats.people],
  ["LinkedIn users with ≥1 pair", stats.users],
  ["Pairs only via master’s", stats.mscOnly],
  ["Pairs only via PhD", stats.phdOnly],
  ["Pairs via both arms", stats.both],
  ["Deduplicated placebo people", stats.placeboPeople],
  ["Placebo people / real people", stats.placeboPeople / stats.people],
];
summary.getRange("A6:B6").format = {
  fill: navy,
  font: { name: font, size: 10, bold: true, color: "#FFFFFF" },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
summary.getRange("A7:A14").format.font = { name: font, size: 10 };
summary.getRange("B7:B14").format.font = { name: font, size: 10, bold: true };
summary.getRange("B7:B13").format.numberFormat = "#,##0";
summary.getRange("B14").format.numberFormat = "0.00%";
summary.getRange("A6:B14").format.borders = {
  bottom: { style: "thin", color: "#D9E2F3" },
};

summary.getRange("D6:E6").values = [["Audit sample", "Value"]];
summary.getRange("D7:D12").values = [
  ["Rows"], ["Master’s only"], ["PhD only"], ["Both arms"],
  ["Blank verdicts"], ["Completed verdicts"],
];
summary.getRange("E7:E12").formulas = [
  ["=COUNTA('Audit sample'!A6:A105)"],
  ["=COUNTIF('Audit sample'!B6:B105,\"msc\")"],
  ["=COUNTIF('Audit sample'!B6:B105,\"phd\")"],
  ["=COUNTIF('Audit sample'!B6:B105,\"msc+phd\")"],
  ["=COUNTBLANK('Audit sample'!AQ6:AQ105)"],
  ["=100-E11"],
];
summary.getRange("D6:E6").format = {
  fill: gray,
  font: { name: font, size: 10, bold: true, color: "#FFFFFF" },
  horizontalAlignment: "center",
  verticalAlignment: "center",
};
summary.getRange("D7:E12").format.font = { name: font, size: 10 };
summary.getRange("E7:E12").format.numberFormat = "#,##0";

summary.getRange("A17:B20").values = [
  ["Matched arm", "Pairs"],
  ["Master’s only", stats.mscOnly],
  ["PhD only", stats.phdOnly],
  ["Both", stats.both],
];
const chart = summary.charts.add("bar", summary.getRange("A17:B20"));
chart.title = "Where each candidate pair enters";
chart.titleTextStyle.typeface = font;
chart.titleTextStyle.fontSize = 12;
chart.hasLegend = false;
chart.xAxis = {
  textStyle: { typeface: font, fontSize: 10 },
  numberFormatCode: "#,##0",
  numberFormatSourceLinked: false,
};
chart.yAxis = { axisType: "textAxis", textStyle: { typeface: font, fontSize: 10 } };
chart.setPosition("D15", "H28");

summary.getRange("A17:B17").format = {
  fill: blue,
  font: { name: font, size: 10, bold: true, color: "#FFFFFF" },
};
summary.getRange("A23:B26").values = [
  ["Review field", "Allowed value"],
  ["verdict", "mesma_pessoa"],
  ["verdict", "pessoa_diferente"],
  ["verdict", "ambiguo"],
];
summary.getRange("A23:B23").format = {
  fill: green,
  font: { name: font, size: 10, bold: true, color: "#FFFFFF" },
};
summary.getRange("A30:H30").merge();
summary.getRange("A30").values = [[
  `Source: ${stats.sourceDir}/capes_obmep_match_candidates.parquet. The 100 rows are deterministically sampled and enriched with the exact diploma rows used to build each arm.`,
]];
summary.getRange("A30:H30").format = {
  font: { name: font, size: 9, italic: true, color: "#666666" },
  wrapText: true,
};
summary.getRange("A30:H30").format.rowHeight = 32;
summary.getRange("A1:H30").format.verticalAlignment = "center";
summary.getRange("A:A").format.columnWidth = 34;
summary.getRange("B:B").format.columnWidth = 15;
summary.getRange("C:C").format.columnWidth = 3;
summary.getRange("D:D").format.columnWidth = 22;
summary.getRange("E:E").format.columnWidth = 14;
summary.getRange("F:H").format.columnWidth = 12;

audit.getRange("A2:AR2").merge();
audit.getRange("A2").values = [["Deterministic audit sample — 100 conservative candidate pairs"]];
audit.getRange("A2:AR2").format = {
  font: { name: font, size: 14, bold: true, color: navy },
};
audit.getRange("A3:AR3").merge();
audit.getRange("A3").values = [[
  "Review the two names and any non-key degree evidence. Fields used by the matching arm already agree by construction. Enter a verdict in column AQ and optional notes in AR.",
]];
audit.getRange("A3:AR3").format = {
  font: { name: font, size: 10, italic: true, color: "#595959" },
};
audit.getRange("A5:AR5").values = [headers];
audit.getRange("A6:AR105").values = rows.map((row) => headers.map((h) => row[h] ?? null));
audit.getRange("A5:AR105").format.font = { name: font, size: 9 };
audit.getRange("A5:AR5").format = {
  fill: navy,
  font: { name: font, size: 9, bold: true, color: "#FFFFFF" },
  horizontalAlignment: "center",
  verticalAlignment: "center",
  wrapText: true,
  borders: { preset: "inside", style: "thin", color: "#FFFFFF" },
};
audit.getRange("A5:L5").format.fill = gray;
audit.getRange("M5:S5").format.fill = blue;
audit.getRange("T5:AA5").format.fill = orange;
audit.getRange("AB5:AH5").format.fill = blue;
audit.getRange("AI5:AP5").format.fill = orange;
audit.getRange("AQ5:AR5").format.fill = green;
audit.getRange("M6:S105").format.fill = lightBlue;
audit.getRange("T6:AA105").format.fill = lightOrange;
audit.getRange("AB6:AH105").format.fill = lightBlue;
audit.getRange("AI6:AP105").format.fill = lightOrange;
audit.getRange("AQ6:AR105").format.fill = lightGreen;
audit.getRange("H6:J105").format.numberFormat = "0.0000";
audit.getRange("F6:F105").format.numberFormat = "0";
audit.getRange("K6:L105").format.numberFormat = "0";
for (const col of ["P", "U", "V", "W", "X", "AE", "AJ", "AK", "AL", "AM"]) {
  audit.getRange(`${col}6:${col}105`).format.numberFormat = "0";
}
audit.getRange("AQ6:AQ105").dataValidation = {
  rule: { type: "list", values: ["mesma_pessoa", "pessoa_diferente", "ambiguo"] },
};
audit.getRange("AQ6:AQ105").conditionalFormats.add("containsText", {
  text: "mesma_pessoa", format: { fill: "#C6E0B4", font: { color: "#375623", bold: true } },
});
audit.getRange("AQ6:AQ105").conditionalFormats.add("containsText", {
  text: "pessoa_diferente", format: { fill: "#F4CCCC", font: { color: "#9C0006", bold: true } },
});
audit.getRange("AQ6:AQ105").conditionalFormats.add("containsText", {
  text: "ambiguo", format: { fill: "#FFE699", font: { color: "#7F6000", bold: true } },
});
const table = audit.tables.add("A5:AR105", true, "MaintainerAuditSample");
table.style = "TableStyleMedium2";
table.showBandedColumns = false;
table.showFilterButton = true;
audit.freezePanes.freezeRows(5);
audit.freezePanes.freezeColumns(7);
audit.getRange("A5:AR105").format.verticalAlignment = "center";
audit.getRange("A5:AR5").format.rowHeight = 42;
audit.getRange("A6:AR105").format.rowHeight = 19;

const widths = {
  A: 34, B: 12, C: 9, D: 9, E: 30, F: 10, G: 30,
  H: 11, I: 12, J: 11, K: 9, L: 9,
  M: 28, N: 25, O: 34, P: 10, Q: 12, R: 18, S: 15,
  T: 26, U: 25, V: 34, W: 10, X: 10, Y: 12, Z: 18, AA: 15,
  AB: 28, AC: 25, AD: 34, AE: 10, AF: 12, AG: 18, AH: 15,
  AI: 26, AJ: 25, AK: 34, AL: 10, AM: 10, AN: 12, AO: 18, AP: 15,
  AQ: 18, AR: 36,
};
for (const [col, width] of Object.entries(widths)) {
  audit.getRange(`${col}:${col}`).format.columnWidth = width;
}
audit.getRange("AR6:AR105").format.wrapText = true;

wb.recalculate();
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.mkdir(previewDir, { recursive: true });
const summaryPreview = await wb.render({
  sheetName: "Summary", autoCrop: "all", scale: 1, format: "png",
});
await fs.writeFile(
  path.join(previewDir, "summary.png"),
  new Uint8Array(await summaryPreview.arrayBuffer()),
);
const auditPreview = await wb.render({
  sheetName: "Audit sample", autoCrop: "all", scale: 0.5, format: "png",
});
await fs.writeFile(
  path.join(previewDir, "audit.png"),
  new Uint8Array(await auditPreview.arrayBuffer()),
);
const inspect = await wb.inspect({
  kind: "sheet,table,formula",
  maxChars: 5000,
  tableMaxRows: 4,
  tableMaxCols: 8,
  options: { maxResults: 30 },
});
console.log(inspect.ndjson);
const errors = await wb.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 100 },
  maxChars: 3000,
});
console.log(errors.ndjson);
const xlsx = await SpreadsheetFile.exportXlsx(wb);
await xlsx.save(outputPath);
console.log(JSON.stringify({ outputPath, rows: rows.length, columns: headers.length }));
