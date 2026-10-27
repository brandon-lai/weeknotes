// Universal links: share links (/u/{token}) open in the app when it's installed.
export const dynamic = "force-static";

export function GET() {
  return Response.json({
    applinks: {
      details: [{ appIDs: ["KT2Y8F24DZ.com.blai.weeknotes"], components: [{ "/": "/u/*", comment: "Share links" }] }],
    },
  });
}
