import { createHash, randomUUID } from "node:crypto";
import { chmodSync, closeSync, constants, fstatSync, linkSync, lstatSync, mkdirSync, openSync, readSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { CacheObservation } from "./cache-estimate";

const MAX_SAMPLES = 64;
const MAX_RECORD_BYTES = 256;
const SAMPLE_FILENAME = /^(\d+(?:\.\d+)?(?:e[+-]\d+)?)-\d+-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$/;

interface Sample {
	at: number;
	gapMs: number;
}

interface CalibrationSummary {
	gapMs: number;
	samples: number;
	lastAt: number;
}

function positiveFinite(value: unknown): value is number {
	return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function privateDirectory(directory: string): void {
	mkdirSync(directory, { recursive: true, mode: 0o700 });
	if (!lstatSync(directory).isDirectory()) throw new Error("Invalid calibration directory");
	chmodSync(directory, 0o700);
}

function readSample(filename: string): Sample | undefined {
	const descriptor = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
	try {
		const stat = fstatSync(descriptor);
		if (!stat.isFile() || stat.size === 0 || stat.size > MAX_RECORD_BYTES) return undefined;
		const buffer = Buffer.alloc(MAX_RECORD_BYTES + 1);
		const length = readSync(descriptor, buffer, 0, buffer.length, 0);
		if (length === 0 || length > MAX_RECORD_BYTES) return undefined;
		let sample: unknown;
		try {
			sample = JSON.parse(buffer.toString("utf8", 0, length));
		} catch {
			return undefined;
		}
		if (typeof sample !== "object" || sample === null || Array.isArray(sample)) return undefined;
		if (!("at" in sample) || !("gapMs" in sample) || !positiveFinite(sample.at) || !positiveFinite(sample.gapMs)) return undefined;
		return { at: sample.at, gapMs: sample.gapMs };
	} finally {
		closeSync(descriptor);
	}
}

/** Historical cache-hit gaps, never an inferred cache lifetime. */
export class CacheCalibration {
	persistent = true;
	private readonly directory: string;
	private readonly routes = new Map<string, Sample[]>();

	constructor(directory?: string) {
		this.directory = directory ?? join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "omp-cache-calibration");
		try {
			privateDirectory(this.directory);
		} catch {
			this.persistent = false;
		}
	}

	record(key: string, gapMs: number, at: number): void {
		if (!positiveFinite(gapMs) || !positiveFinite(at)) return;
		const route = createHash("sha256").update(key).digest("hex");
		const samples = this.samplesFor(route);
		samples.push({ at, gapMs });
		samples.sort((left, right) => left.at - right.at);
		if (samples.length > MAX_SAMPLES) samples.shift();
		if (!this.persistent) return;
		try {
			const directory = join(this.directory, route);
			const filename = `${at}-${process.pid}-${randomUUID()}.json`;
			const temporary = join(directory, `.${filename}.tmp`);
			writeFileSync(temporary, JSON.stringify({ at, gapMs }), { flag: "wx", mode: 0o600 });
			try {
				// Publish only complete records, atomically and without overwrite.
				linkSync(temporary, join(directory, filename));
			} finally {
				unlinkSync(temporary);
			}
			this.retainedFiles(directory);
		} catch {
			this.persistent = false;
		}
	}

	summary(key: string): CalibrationSummary | undefined {
		const route = createHash("sha256").update(key).digest("hex");
		const samples = this.samplesFor(route);
		if (samples.length === 0) return undefined;
		let gapMs = 0;
		for (const sample of samples) gapMs = Math.max(gapMs, sample.gapMs);
		return { gapMs, samples: samples.length, lastAt: samples[samples.length - 1].at };
	}

	private samplesFor(route: string): Sample[] {
		const cached = this.routes.get(route);
		if (cached) return cached;
		const samples: Sample[] = [];
		this.routes.set(route, samples);
		if (!this.persistent) return samples;
		try {
			const directory = join(this.directory, route);
			privateDirectory(directory);
			for (const filename of this.retainedFiles(directory)) {
				try {
					const sample = readSample(join(directory, filename));
					if (sample) samples.push(sample);
				} catch (error) {
					if (!(typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT")) this.persistent = false;
				}
			}
		} catch {
			this.persistent = false;
		}
		return samples;
	}

	private retainedFiles(directory: string): string[] {
		const files: { filename: string; at: number }[] = [];
		for (const filename of readdirSync(directory)) {
			const match = SAMPLE_FILENAME.exec(filename);
			if (!match) continue;
			const at = Number(match[1]);
			if (positiveFinite(at)) files.push({ filename, at });
		}
		files.sort((left, right) => left.at - right.at || left.filename.localeCompare(right.filename));
		const excess = Math.max(0, files.length - MAX_SAMPLES);
		for (let index = 0; index < excess; index++) {
			try {
				unlinkSync(join(directory, files[index].filename));
			} catch (error) {
				if (!(typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT")) throw error;
			}
		}
		return files.slice(excess).map(file => file.filename);
	}
}

function formatDuration(milliseconds: number): string {
	return milliseconds >= 60_000 ? `${Math.floor(milliseconds / 60_000)}m` : `${Math.floor(Math.max(0, milliseconds) / 1000)}s`;
}

export function formatCacheDetails(
	observation: CacheObservation | undefined,
	summary: { gapMs: number; samples: number } | undefined,
	now: number,
	historicTier: "short" | "long" | undefined,
	persistent: boolean,
): string[] {
	const lines = [
		observation
			? `Last confirmed cache ${observation.kind === "hit" ? "hit" : "write"} for the current prefix: ${formatDuration(now - observation.at)} ago.`
			: "No confirmed cache hit or write for the current prefix.",
		summary && positiveFinite(summary.gapMs)
			? `Longest observed idle gap followed by cache reuse: ${formatDuration(summary.gapMs)} (${summary.samples} ${summary.samples === 1 ? "sample" : "samples"}).`
			: "No qualifying idle gap followed by cache reuse yet; calibration is still learning.",
	];
	if (historicTier) lines.push(`Historical cache policy: ${historicTier} retention.`);
	lines.push(
		persistent
			? "Calibration storage is available; qualifying observations can be saved."
			: "Calibration storage is unavailable; observations are kept in memory only.",
		"Observed idle gaps describe cache reuse, not a cache lifetime or expiry time.",
	);
	return lines;
}
