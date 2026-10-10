export const STATUS_LINE_SET = "com.brannon.status-line/set";
export const STATUS_LINE_REMOVE = "com.brannon.status-line/remove";
export const STATUS_LINE_REQUEST = "com.brannon.status-line/request";

export type StatusLineTone = "success" | "warning" | "error" | "dim";

export interface StatusLineSegment {
	sessionId: string;
	id: string;
	order: number;
	text: string;
	tone: StatusLineTone;
}

export interface StatusLineRemoval {
	sessionId: string;
	id: string;
}

export interface StatusLineRequest {
	sessionId: string;
}
