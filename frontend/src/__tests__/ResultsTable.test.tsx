import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ResultsTable } from "../components/ResultsTable";
import type { VideoItem } from "../api/client";

const okItem: VideoItem = {
  objectKey: "videos/CAM01_20260921_080000-083000.mp4",
  cameraId: "01",
  recordedAtUtc: "2026-09-21T11:00:00+00:00",
  recordedAtLocal: "2026-09-21T08:00:00-03:00",
  sizeBytes: 1_200_000_000,
  catalogStatus: "OK",
  storageClass: "STANDARD",
  stableId: "abc123",
};
const invalidItem: VideoItem = {
  ...okItem,
  stableId: "bad1",
  catalogStatus: "INVALID_METADATA",
  cameraId: null,
};

describe("ResultsTable states", () => {
  it("shows a loading indicator", () => {
    render(<ResultsTable state="loading" items={[]} onDownload={() => {}} />);
    expect(screen.getByLabelText(/cargando resultados/i)).toBeInTheDocument();
  });

  it("shows an error alert", () => {
    render(<ResultsTable state="error" items={[]} onDownload={() => {}} />);
    expect(screen.getByRole("alert")).toHaveTextContent(/no pudimos completar/i);
  });

  it("shows an empty message", () => {
    render(<ResultsTable state="loaded" items={[]} onDownload={() => {}} />);
    expect(screen.getByText(/no se encontraron grabaciones/i)).toBeInTheDocument();
  });

  it("renders a table with a downloadable row", () => {
    const onDownload = vi.fn();
    render(<ResultsTable state="loaded" items={[okItem]} onDownload={onDownload} />);
    expect(screen.getByRole("table", { name: /resultados/i })).toBeInTheDocument();
    const btn = screen.getByRole("button", { name: /descargar/i });
    expect(btn).toBeEnabled();
    btn.click();
    expect(onDownload).toHaveBeenCalledWith(okItem);
  });

  it("disables the action for invalid-metadata rows", () => {
    render(<ResultsTable state="loaded" items={[invalidItem]} onDownload={() => {}} />);
    expect(screen.getByText(/metadata inválida/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /no disponible/i })).toBeDisabled();
  });

  it("shows archived and deleted lifecycle states as unavailable", () => {
    const archived = { ...okItem, stableId: "arc1", lifecycleState: "ARCHIVED" as const };
    const deleted = {
      ...okItem,
      stableId: "del1",
      lifecycleState: "DELETED" as const,
      deleted: true,
      deletedAt: "2026-10-22T13:00:00Z",
    };
    render(
      <ResultsTable state="loaded" items={[archived, deleted]} onDownload={() => {}} />,
    );
    expect(screen.getByText(/archivado; requiere restauración/i)).toBeInTheDocument();
    expect(screen.getByText(/^eliminado$/i)).toBeInTheDocument();
    for (const button of screen.getAllByRole("button", { name: /no disponible/i })) {
      expect(button).toBeDisabled();
    }
  });

  it("allows download for a temporarily restored object", () => {
    const restored = { ...okItem, stableId: "res1", lifecycleState: "RESTORED" as const };
    render(<ResultsTable state="loaded" items={[restored]} onDownload={() => {}} />);
    expect(screen.getByText(/restaurado temporalmente/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /descargar/i })).toBeEnabled();
  });
});
