import { useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import TextField from "@mui/material/TextField";
import SearchIcon from "@mui/icons-material/Search";
import type { SearchParams } from "../api/client";

/**
 * Filter bar. Every control has an explicit label (accessibility + R "search
 * controls MUST have explicit labels"). Emits a validated SearchParams object.
 */
export function SearchBar({
  onSearch,
  disabled,
}: {
  onSearch: (p: SearchParams) => void;
  disabled?: boolean;
}) {
  const [date, setDate] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [camera, setCamera] = useState("");

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    onSearch({
      date: date || undefined,
      from: from || undefined,
      to: to || undefined,
      camera: camera || undefined,
    });
  };

  return (
    <Box
      component="form"
      onSubmit={submit}
      sx={{
        display: "flex",
        gap: 2,
        alignItems: "flex-end",
        flexWrap: "wrap",
        p: 2.5,
        bgcolor: "background.paper",
        border: 1,
        borderColor: "divider",
        borderRadius: 2,
      }}
    >
      <TextField
        label="Fecha"
        type="date"
        value={date}
        onChange={(e) => setDate(e.target.value)}
        slotProps={{ inputLabel: { shrink: true } }}
        size="small"
      />
      <TextField
        label="Desde"
        type="time"
        value={from}
        onChange={(e) => setFrom(e.target.value)}
        slotProps={{ inputLabel: { shrink: true } }}
        size="small"
      />
      <TextField
        label="Hasta"
        type="time"
        value={to}
        onChange={(e) => setTo(e.target.value)}
        slotProps={{ inputLabel: { shrink: true } }}
        size="small"
      />
      <TextField
        label="Cámara"
        placeholder="Todas"
        value={camera}
        onChange={(e) => setCamera(e.target.value)}
        size="small"
      />
      <Button type="submit" variant="contained" startIcon={<SearchIcon />} disabled={disabled}>
        Buscar
      </Button>
    </Box>
  );
}
