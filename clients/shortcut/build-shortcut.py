#!/usr/bin/env python3
"""Build the iPhone/Mac Shortcut "Thought" for memohub as an unsigned .shortcut plist.

    python3 -I build-shortcut.py <url> <publishable apikey> <out.shortcut>
    shortcuts sign --mode people-who-know-me --input <out.shortcut> --output Thought.shortcut

The device key is NOT built in: the first action is a Text field "PASTE_DEVICE_KEY" that the
user replaces with the key from scripts/device-key.sh in the Shortcuts editor.
"""
import plistlib
import sys
import uuid

OBJ = "￼"


def uid():
    return str(uuid.uuid4()).upper()


def out_ref(u, name):
    return {"OutputUUID": u, "Type": "ActionOutput", "OutputName": name}


INPUT_REF = {"Type": "ExtensionInput"}


def text(s, refs=None):
    """WFTextTokenString; refs maps position of each OBJ in s to a reference dict."""
    attach = {}
    if refs:
        positions = [i for i, ch in enumerate(s) if ch == OBJ]
        for pos, ref in zip(positions, refs):
            attach["{%d, 1}" % pos] = ref
    return {"Value": {"string": s, "attachmentsByRange": attach}, "WFSerializationType": "WFTextTokenString"}


def var(ref):
    return {"Value": ref, "WFSerializationType": "WFTextTokenAttachment"}


def dict_field(items):
    return {"Value": {"WFDictionaryFieldValueItems": [
        {"WFItemType": 0, "WFKey": text(k), "WFValue": v} for k, v in items]},
        "WFSerializationType": "WFDictionaryFieldValue"}


def action(ident, params):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions." + ident, "WFWorkflowActionParameters": params}


def build(url, apikey):
    K, D, F, R, I, U, V, G = (uid() for _ in range(8))
    acts = [
        action("comment", {"WFCommentActionText": "memohub: a thought into the journal. Replace PASTE_DEVICE_KEY below with the key "
                                                   "from scripts/device-key.sh create iphone. The key can only add thoughts."}),
        action("gettext", {"UUID": K, "WFTextActionText": "PASTE_DEVICE_KEY"}),
        action("date", {"UUID": D, "WFDateActionMode": "Current Date"}),
        action("format.date", {"UUID": F, "WFDateFormatStyle": "Custom", "WFDateFormat": "yyyyMMddHHmmssSSS",
                               "WFDate": text(OBJ, [out_ref(D, "Date")])}),
        action("number.random", {"UUID": R, "WFRandomNumberMinimum": 1000, "WFRandomNumberMaximum": 9999}),
        action("gettext", {"UUID": I, "WFTextActionText": text("sc-" + OBJ + "-" + OBJ,
                                                               [out_ref(F, "Formatted Date"), out_ref(R, "Random Number")])}),
        action("downloadurl", {
            "UUID": U, "WFURL": url, "WFHTTPMethod": "POST", "ShowHeaders": True,
            "WFHTTPHeaders": dict_field([("apikey", text(apikey)), ("Content-Profile", text("memohub_api")),
                                         ("Content-Type", text("application/json"))]),
            "WFHTTPBodyType": "JSON",
            "WFJSONValues": dict_field([("p_key", text(OBJ, [out_ref(K, "Text")])),
                                        ("p_text", text(OBJ, [INPUT_REF])),
                                        ("p_id", text(OBJ, [out_ref(I, "Text")]))]),
        }),
        action("getvalueforkey", {"UUID": V, "WFGetDictionaryValueType": "Value", "WFDictionaryKey": "saved",
                                  "WFInput": var(out_ref(U, "Contents of URL"))}),
        action("conditional", {"GroupingIdentifier": G, "WFControlFlowMode": 0, "WFCondition": 100,
                               "WFInput": {"Type": "Variable", "Variable": var(out_ref(V, "Dictionary Value"))}}),
        action("notification", {"WFNotificationActionTitle": "memohub", "WFNotificationActionBody": "Thought saved"}),
        action("conditional", {"GroupingIdentifier": G, "WFControlFlowMode": 1}),
        action("setclipboard", {"WFInput": var(INPUT_REF)}),
        action("alert", {"WFAlertActionTitle": "Not saved",
                         "WFAlertActionMessage": text("The text is in the clipboard. Reply: " + OBJ, [out_ref(U, "Contents of URL")]),
                         "WFAlertActionCancelButtonShown": False}),
        action("conditional", {"GroupingIdentifier": G, "WFControlFlowMode": 2}),
    ]
    return {
        "WFWorkflowActions": acts,
        "WFWorkflowClientVersion": "2605.0.5",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["ActionExtension", "Watch"],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFURLContentItem", "WFRichTextContentItem"],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowNoInputBehavior": {"Name": "WFWorkflowNoInputBehaviorAskForInput",
                                      "Parameters": {"ItemClass": "WFStringContentItem"}},
        "WFWorkflowOutputContentItemClasses": [],
    }


if __name__ == "__main__":
    url, apikey, out = sys.argv[1:4]
    with open(out, "wb") as f:
        plistlib.dump(build(url, apikey), f, fmt=plistlib.FMT_BINARY)
    print("unsigned:", out)
