import { useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input, Textarea } from "@/components/ui/input";
import { useHermes } from "@/lib/store";

export function LearnSkillButton() {
  const [open, setOpen] = useState(false);
  const [dir, setDir] = useState("");
  const [url, setUrl] = useState("");
  const [text, setText] = useState("");
  const navigate = useNavigate();
  const setDraft = useHermes((s) => s.setDraft);
  const newChat = useHermes((s) => s.newChat);
  const learnSkill = useHermes((s) => s.learnSkill);

  function submit() {
    const bits = [
      dir && `directorio: ${dir}`,
      url && `url: ${url}`,
      text && `notas: ${text}`,
    ].filter(Boolean);
    if (bits.length === 0) return;
    learnSkill({ name: text || url || dir, from: bits.join(" · ") });
    newChat();
    setDraft(`/learn ${bits.join("\n")}`);
    setOpen(false);
    setDir("");
    setUrl("");
    setText("");
    void navigate({ to: "/" });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>Aprender una skill</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Aprender una skill</DialogTitle>
          <DialogDescription>
            Un directorio, una URL o unas notas. Hermes lo convierte en una
            habilidad y te pide confirmación antes de escribir.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <label className="flex flex-col gap-1.5 text-sm">
            Directorio
            <Input
              value={dir}
              onChange={(e) => setDir(e.target.value)}
              placeholder="~/proyectos/mi-skill"
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            URL
            <Input
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder="https://…"
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            O descríbela
            <Textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder="Cómo hago el briefing de los lunes…"
              className="min-h-24 rounded-md bg-muted px-3 py-2 shadow-border"
            />
          </label>
          <div className="flex justify-end">
            <Button onClick={submit} disabled={!dir && !url && !text.trim()}>
              Enviar a Hermes
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
