import { strictParse, validateProtocolRecord } from "./strict-json.mjs";

const DEFAULT_MAXIMUM_RECORD_BYTES = 1_048_576;

export class FrameDecoder {
  constructor({ maximumRecordBytes = DEFAULT_MAXIMUM_RECORD_BYTES } = {}) {
    this.maximumRecordBytes = maximumRecordBytes;
    this.pending = Buffer.alloc(0);
    this.decoder = new TextDecoder("utf-8", { fatal: true });
  }

  push(chunk) {
    if (!Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk);
    this.pending = Buffer.concat([this.pending, chunk]);
    const records = [];

    while (true) {
      const newline = this.pending.indexOf(0x0a);
      if (newline < 0) {
        if (this.pending.length > this.maximumRecordBytes) throw protocolError("record_too_large");
        return records;
      }
      if (newline > this.maximumRecordBytes) throw protocolError("record_too_large");
      const frame = this.pending.subarray(0, newline);
      this.pending = this.pending.subarray(newline + 1);
      if (frame.includes(0x00) || frame.includes(0x0d)) throw protocolError("invalid_record");
      try {
        const record = strictParse(this.decoder.decode(frame));
        validateProtocolRecord(record);
        records.push(record);
      } catch {
        throw protocolError("invalid_record");
      }
    }
  }

  end() {
    if (this.pending.length !== 0) throw protocolError("invalid_record");
  }
}

export function writeRecord(stream, record) {
  validateProtocolRecord(record);
  const bytes = Buffer.from(`${JSON.stringify(record)}\n`);
  if (bytes.length - 1 > DEFAULT_MAXIMUM_RECORD_BYTES) throw protocolError("record_too_large");
  stream.write(bytes);
}

function protocolError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}
