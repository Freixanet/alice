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
import { useT } from "@/lib/use-i18n";

export function LearnSkillButton() {
  const t = useT();
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
      dir && t("learn.dir", { value: dir }),
      url && t("learn.urlBit", { value: url }),
      text && t("learn.notesBit", { value: text }),
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
        <Button>{t("learn.button")}</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("learn.title")}</DialogTitle>
          <DialogDescription>{t("learn.hint")}</DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <label className="flex flex-col gap-1.5 text-sm">
            {t("learn.directory")}
            <Input
              value={dir}
              onChange={(e) => setDir(e.target.value)}
              placeholder="~/projects/my-skill"
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("learn.url")}
            <Input
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder="https://…"
            />
          </label>
          <label className="flex flex-col gap-1.5 text-sm">
            {t("learn.describe")}
            <Textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder={t("learn.describePlaceholder")}
              className="min-h-24 rounded-md bg-muted px-3 py-2 shadow-border"
            />
          </label>
          <div className="flex justify-end">
            <Button onClick={submit} disabled={!dir && !url && !text.trim()}>
              {t("learn.submit")}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
