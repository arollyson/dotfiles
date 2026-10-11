export const STATUS_LINE_SET = "dotfiles.status-line/set";
export const STATUS_LINE_REMOVE = "dotfiles.status-line/remove";
export const STATUS_LINE_REQUEST = "dotfiles.status-line/request";

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
